// handlers/messageHandler.js
import { saveMessage } from '../db/message.js';
import { UserStateManager } from '../db/state.js';
import { UserManager } from '../db/user.js';
import { trackInteraction } from '../db/interaction.js';
import * as Admin from '../db/admin.js';
import { LANG_NAMES, t } from '../i18n.js';
import mainMenuButtons from './mainMenuButtons.js';
import generateImage from '../services/runwareImageGen.js';
import { SponsoredInviteLinks } from '../db/sponsoredInviteLinks.js';
import { safeApiCall } from '../utils/safeApiCall.js';
import { MESSAGE_REACTIONS } from '../utils/reactionsEmos.js';
import { sleep } from "../utils/sleep.js";
import { parseInviteEditArgs } from "../utils/parseInviteEditArgs.js";
import { parseChatId } from "../utils/parseChatId.js";
import { getMessageId } from "../utils/getMessageId.js";
import { react } from "../utils/react.js";

const { ADMIN_ID } = process.env;
const ADMIN_ID_INT = parseInt(ADMIN_ID, 10) || 0;
const FAKE_GEN_DELAY_SECS = parseFloat(process.env.FAKE_GEN_DELAY_SECS) || 30;
const startedAt = new Date();


export async function handleMessage({ update, tg, tgQueue, res }) {
  if (!tgQueue._hasErrorHandler) {
    tgQueue._hasErrorHandler = true;
    process.on('unhandledRejection', err => {
      console.error('[QUEUE] Unhandled rejection → clearing queue', err);
      tgQueue.clearQueue();
    });
  }

  const msg = update.message;
  const chatId = Number(msg.chat.id);
  const fromId = Number(msg.from.id);
  const username = msg.from.username || '';
  const text = (msg.text || '').trim();
  const userMessageId = msg.message_id;

  await saveMessage(chatId, fromId, username, text);
  await trackInteraction({
    user_id: fromId,
    chat_id: chatId,
    type: text.startsWith('/') ? 'command' : 'text',
    payload: text,
    message_id: userMessageId
  });

  const isNewUser = await UserManager.upsertUser(msg.from);
  const userInfo = await UserManager.getUser(fromId);
  const lang = userInfo?.selected_lang || 'en';
  const state = await UserStateManager.getState(fromId, chatId);

  // --- IMAGE GENERATION FLOW ---
  if (state?.menu_state === 'awaiting_prompt' && state.data?.modelId) {
    const modelId = state.data.modelId;

    // React to the user's prompt being received
    await react(tgQueue, tg, chatId, msg.message_id, MESSAGE_REACTIONS.PROMPT_RECEIVED);

    // 1) Delete the "ask for prompt" UI immediately for a cleaner flow
    try {
      const prevPromptMsgId = state?.data?.last_prompt_message_id;
      if (prevPromptMsgId) {
        await safeApiCall(
          tgQueue, tg,
          tg.deleteMessage.bind(tg),
          [chatId, prevPromptMsgId],
          chatId
        );
      }
    } catch (err) {
      console.error('[IMAGE_GEN] Failed to delete previous prompt message:', err);
    }

    // Move to generating_image state
    await UserStateManager.setState(fromId, chatId, 'generating_image', {
      modelId: modelId,
      startTime: Date.now()
    });

    let generatingMessageId = null;
    let hasSucceeded = false;
    let deliveredImageMessageId = null;

    try {
      const delaySecs = FAKE_GEN_DELAY_SECS > 0 ? Math.ceil(FAKE_GEN_DELAY_SECS) : 0;

      // 2) Send a fresh progress message (not editing prior UI, since we deleted it)
      if (delaySecs > 0) {
        const genMsg = await safeApiCall(
          tgQueue, tg,
          tg.sendMessage.bind(tg),
          [chatId, t(lang, 'GENERATING_IMAGE', { seconds: delaySecs })],
          chatId,
          'Preparing to generate your image...'
        );
        generatingMessageId = genMsg?.message_id || genMsg?.result?.message_id;
        await react(tgQueue, tg, chatId, generatingMessageId, MESSAGE_REACTIONS.GENERATING_TICK);

        // Countdown updates (edit only the progress message)
        let remaining = delaySecs;
        while (remaining > 0 && generatingMessageId) {
          const chunk = Math.min(remaining, 5);
          await sleep(chunk * 1000);
          remaining -= chunk;
          if (remaining > 0) {
            await safeApiCall(
              tgQueue, tg,
              tg.editMessageText.bind(tg),
              [chatId, generatingMessageId, t(lang, 'GENERATING_IMAGE', { seconds: remaining })],
              chatId
            );
            await react(tgQueue, tg, chatId, generatingMessageId, MESSAGE_REACTIONS.GENERATING_TICK);
          }
        }
      } else {
        const genMsg = await safeApiCall(
          tgQueue, tg,
          tg.sendMessage.bind(tg),
          [chatId, t(lang, 'GENERATING_IMAGE', { seconds: 0 })],
          chatId,
          'Generating your image...'
        );
        generatingMessageId = genMsg?.message_id || genMsg?.result?.message_id;
      }

      // Switch the progress line to "Creating…"
      if (generatingMessageId) {
        await safeApiCall(
          tgQueue, tg,
          tg.editMessageText.bind(tg),
          [chatId, generatingMessageId, '🎨 Creating your image...'],
          chatId
        );
        await react(tgQueue, tg, chatId, generatingMessageId, MESSAGE_REACTIONS.GENERATING_START, { is_big: true });
      }

      // 3) Generate with timeout
      const IMAGE_TIMEOUT_MS = 90000;
      const imageGenerationPromise = (async () => {
        const result = await generateImage(text, modelId);
        return result;
      })();
      const timeoutPromise = new Promise((_, reject) => {
        setTimeout(() => reject(new Error('Image generation timed out')), IMAGE_TIMEOUT_MS);
      });

      const imageDetails = await Promise.race([imageGenerationPromise, timeoutPromise]);
      if (!imageDetails || !imageDetails.imageUrl) {
        throw new Error('No image URL returned from generation service');
      }

      // 4) Send the image
      const imageSent = await safeApiCall(
        tgQueue, tg,
        tg.sendPhoto.bind(tg),
        [
          chatId,
          imageDetails.imageUrl,
          {
            caption: t(lang, 'IMAGE_GENERATED', { model: modelId }),
            parse_mode: 'HTML'
          }
        ],
        chatId,
        'Image generated successfully!'
      );
      hasSucceeded = true;
      deliveredImageMessageId = imageSent?.message_id || imageSent?.result?.message_id;

      await react(tgQueue, tg, chatId, deliveredImageMessageId, MESSAGE_REACTIONS.GENERATING_DONE, { is_big: true });

      // Auto-delete the generated image after 10s (optional, as before)
      if (deliveredImageMessageId) {
        setTimeout(() => {
          safeApiCall(
            tgQueue, tg,
            tg.deleteMessage.bind(tg),
            [chatId, deliveredImageMessageId],
            chatId
          ).catch(() => {});
        }, 10000);
      }

      // 5) Clean up the progress message
      if (generatingMessageId) {
        try {
          await safeApiCall(
            tgQueue, tg,
            tg.deleteMessage.bind(tg),
            [chatId, generatingMessageId],
            chatId
          );
        } catch {}
      }
    } catch (error) {
      console.error('[IMAGE_GEN ERROR]', error);

      // Select friendly error text
      let errorMessage;
      const msgText = String(error?.message || '');
      if (msgText.includes('timed out')) {
        errorMessage = t(lang, 'GENERIC_IMAGE_TIMEOUT') ||
          '⏱️ Image generation is taking longer than expected. Please try again with a simpler prompt.';
      } else if (msgText.includes('API Error')) {
        errorMessage = t(lang, 'GENERIC_IMAGE_API_ERROR') ||
          '🔧 Our image service is temporarily unavailable. Please try again in a few minutes.';
      } else {
        errorMessage = t(lang, 'GENERIC_IMAGE_ERROR') ||
          '❌ Sorry, we couldn\'t generate your image. Please try again later.';
      }

      // Remove progress message if it exists
      if (generatingMessageId) {
        try {
          await safeApiCall(
            tgQueue, tg,
            tg.deleteMessage.bind(tg),
            [chatId, generatingMessageId],
            chatId
          );
        } catch {}
      }

      // Mark the user's prompt as failed
      await react(tgQueue, tg, chatId, msg.message_id, MESSAGE_REACTIONS.GENERATING_FAILED, { is_big: true });

      // Send error
      await safeApiCall(
        tgQueue, tg,
        tg.sendMessage.bind(tg),
        [chatId, errorMessage],
        chatId,
        'Sorry, image generation failed.'
      );

      // Back to menu
      await UserStateManager.setState(fromId, chatId, 'menu', {});
      const menuMsg = await safeApiCall(
        tgQueue, tg,
        tg.sendMessage.bind(tg),
        [chatId, t(lang, 'MENU_TITLE'), {
          parse_mode: 'HTML',
          reply_markup: { inline_keyboard: mainMenuButtons(lang) }
        }],
        chatId,
        'Menu'
      );
      const menuId = menuMsg?.message_id || menuMsg?.result?.message_id;
      await UserStateManager.setState(fromId, chatId, 'menu', {}, menuId);
      await react(tgQueue, tg, chatId, menuId, MESSAGE_REACTIONS.MENU_SHOWN);

      return res.sendStatus(200);
    }

    // Success path → show menu
    if (hasSucceeded) {
      const menuMsg = await safeApiCall(
        tgQueue, tg,
        tg.sendMessage.bind(tg),
        [chatId, t(lang, 'MENU_TITLE'), {
          parse_mode: 'HTML',
          reply_markup: { inline_keyboard: mainMenuButtons(lang) }
        }],
        chatId,
        'What would you like to do next?'
      );
      const menuId = menuMsg?.message_id || menuMsg?.result?.message_id;
      await UserStateManager.setState(fromId, chatId, 'menu', {}, menuId);
      await react(tgQueue, tg, chatId, menuId, MESSAGE_REACTIONS.MENU_SHOWN);
    }

    return res.sendStatus(200);
  }

  // --- ADMIN COMMANDS (enhanced) ---
  if (ADMIN_ID_INT && fromId === ADMIN_ID_INT) {
    // Mark admin command received
    if (text.startsWith('/')) {
      await react(tgQueue, tg, chatId, userMessageId, MESSAGE_REACTIONS.ADMIN_CMD);
    }

    // ---------- helpers ----------
    const getMsgId = (m) => Number(m?.message_id || m?.result?.message_id);
    const esc = (s = '') =>
      String(s)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');

    const fmtDate = (d) => (d ? new Date(d).toLocaleString() : '-');

    const fmtSec = (sec) => {
      if (!sec || sec <= 0) return 'never';
      const h = Math.floor(sec / 3600);
      const m = Math.floor((sec % 3600) / 60);
      const s = sec % 60;
      const parts = [];
      if (h) parts.push(`${h}h`);
      if (m) parts.push(`${m}m`);
      if (s || parts.length === 0) parts.push(`${s}s`);
      return parts.join(' ');
    };

    // Parse: supports
    //   /addinvite <chat_id> [name] [limit] [expire_sec]
    //   /addinvite <chat_id> name="VIP" limit=200 expire=3600
    //   /addinvite <chat_id> --name="VIP" --limit=200 --expire=3600
    function parseArgs(rawParts) {
      const args = { _: [] };
      for (const p of rawParts) {
        if (!p) continue;
        const mKV = p.match(/^(?:--)?([a-zA-Z_]+)=(.*)$/);
        if (mKV) {
          const k = mKV[1].toLowerCase();
          let v = mKV[2];
          // strip quotes if present
          const q = v.match(/^"(.*)"$/) || v.match(/^'(.*)'$/);
          if (q) v = q[1];
          args[k] = v;
          continue;
        }
        const mFlag = p.match(/^--([a-zA-Z_]+)$/);
        if (mFlag) {
          args[mFlag[1].toLowerCase()] = true;
          continue;
        }
        args._.push(p);
      }
      return args;
    }

    function parseChatId(parts) {
      // Accepts first positional token that looks like a number (including negative)
      // e.g. -1001234567890
      for (const token of parts) {
        if (/^-?\d+$/.test(token)) return token.trim();
      }
      return null;
    }

    function chunkMessages(lines, maxLen = 3600) {
      const chunks = [];
      let buf = '';
      for (const line of lines) {
        if ((buf + line + '\n').length > maxLen) {
          chunks.push(buf);
          buf = '';
        }
        buf += line + '\n';
      }
      if (buf) chunks.push(buf);
      return chunks;
    }

    async function sendHTML(html) {
      const sent = await safeApiCall(
        tgQueue, tg, tg.sendMessage.bind(tg),
        [chatId, html, { parse_mode: 'HTML', disable_web_page_preview: true }],
        chatId
      );
      if (sent?.ok === false && sent?.description) {
        // Fallback to plain text if parse failed for any reason
        return await tg.sendMessage(chatId, html.replace(/<[^>]+>/g, ''));
      }
      return sent;
    }

    // ---------- /invitehelp ----------
    if (/^\/invitehelp$/.test(text)) {
      const help = [
        `<b>Sponsored Invite Link — Admin Commands</b>`,
        ``,
        `<b>/addinvite &lt;chat_id&gt; [name] [limit] [expire_sec]</b>`,
        `— Create and start tracking an invite link for a channel/group.`,
        `  • <code>chat_id</code> (required)`,
        `  • <code>name</code> (optional)`,
        `  • <code>limit</code> (optional) user quota for this link`,
        `  • <code>expire_sec</code> (optional) lifetime in seconds`,
        `  Also supports flags: <code>name="VIP"</code> <code>limit=200</code> <code>expire=3600</code>`,
        ``,
        `<b>/removeinvite &lt;chat_id&gt;</b>`,
        `— Revoke the link and delete its DB row.`,
        ``,
        `<b>/revokeinvite &lt;chat_id&gt;</b>`,
        `— Revoke (invalidate) the link but keep the row (status → revoked).`,
        ``,
        `<b>/editinvite &lt;chat_id&gt; param=value ...</b>`,
        `— Edit invite parameters: <code>limit</code>, <code>expire</code> (seconds), <code>name</code>.`,
        `  Example: /editinvite -100123456 limit=200 expire=3600 name="VIP Only"`,
        ``,
        `<b>/inviteinfo &lt;chat_id&gt;</b>`,
        `— Show full details + stats (link_joins vs total_joins).`,
        ``,
        `<b>/invites</b>`,
        `— List all tracked invites with status & key stats.`,
      ].join('\n');
      const sent = await sendHTML(help);
      await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_OK);
      return res.sendStatus(200);
    }

    // ---------- /addinvite ----------
    if (/^\/addinvite\b/i.test(text)) {
      const parts = text.trim().split(/\s+/).slice(1); // drop cmd
      const args = parseArgs(parts);
      const chat_id = parseChatId(args._);
      const link_name = args.name ?? args._[1];
      const limit = (args.limit ?? args._[2]) ? parseInt(args.limit ?? args._[2], 10) : undefined;
      const expire_sec = (args.expire ?? args._[3]) ? parseInt(args.expire ?? args._[3], 10) : undefined;

      if (!chat_id) {
        const sent = await tg.sendMessage(
          chatId,
          'Usage: /addinvite <chat_id> [name] [limit] [expire_sec]\nAlso: /addinvite <chat_id> name="VIP" limit=200 expire=3600'
        );
        await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
        return res.sendStatus(200);
      }

      try {
        const params = {};
        if (link_name) params.name = link_name;
        if (Number.isFinite(limit) && limit > 0) params.member_limit = limit;
        if (Number.isFinite(expire_sec) && expire_sec > 0) {
          params.expire_date = Math.floor(Date.now() / 1000) + expire_sec;
        }

        const linkObj = await tg.createChatInviteLink(chat_id, params);
        const chatInfo = await tg.getChat(chat_id);

        await SponsoredInviteLinks.addOrUpdateLink({
          chat_id,
          invite_link: linkObj.invite_link,
          link_name: linkObj.name ?? link_name ?? null,
          chat_title: chatInfo.title,
          chat_username: chatInfo.username,
          join_limit: linkObj.member_limit ?? limit ?? null,
          expire_date: linkObj.expire_date ? new Date(linkObj.expire_date * 1000) : (expire_sec ? new Date(Date.now() + expire_sec * 1000) : null)
        });

        const summary = [
          `✅ <b>Invite created</b> for <b>${esc(chatInfo.title || chat_id)}</b>`,
          `Invite: <code>${esc(linkObj.invite_link)}</code>`,
          `Name: <code>${esc(linkObj.name ?? link_name ?? '(none)')}</code>`,
          `Limit: <b>${linkObj.member_limit ?? limit ?? '∞'}</b>`,
          `Expires: <b>${expire_sec ? fmtSec(expire_sec) : (linkObj.expire_date ? fmtDate(new Date(linkObj.expire_date * 1000)) : 'never')}</b>`,
          `• Per-link joins start at <b>0</b>; remaining_joins derived from limit.`,
        ].join('\n');

        const sent = await sendHTML(summary);
        await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_OK);
      } catch (err) {
        console.error('[ADMIN /addinvite ERROR]', err);
        const sent = await tg.sendMessage(chatId, t?.(lang, 'GENERIC_ERROR') ?? 'Something went wrong.');
        await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
      }
      return res.sendStatus(200);
    }

    // ---------- /removeinvite ----------
    if (/^\/removeinvite\b/i.test(text)) {
      const parts = text.split(/\s+/);
      const chat_id = parseChatId(parts);
      if (!chat_id) {
        const sent = await tg.sendMessage(chatId, 'Usage: /removeinvite <chat_id>');
        await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
        return res.sendStatus(200);
      }
      try {
        const row = await SponsoredInviteLinks.getLink(chat_id);
        if (row) {
          try { await tg.revokeChatInviteLink(chat_id, row.invite_link); } catch (e) {
            console.warn('[ADMIN /removeinvite revoke warn]', e?.description || e);
          }
          await SponsoredInviteLinks.removeLink(chat_id);

          const summary = [
            `✅ Removed & revoked invite for <b>${esc(row.chat_title || chat_id)}</b>`,
            `• This also deletes tracking data for the current link.`,
          ].join('\n');
          const sent = await sendHTML(summary);
          await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_OK);
        } else {
          const sent = await tg.sendMessage(chatId, 'Not found in DB.');
          await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
        }
      } catch (err) {
        console.error('[ADMIN /removeinvite ERROR]', err);
        const sent = await tg.sendMessage(chatId, t?.(lang, 'GENERIC_ERROR') ?? 'Something went wrong.');
        await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
      }
      return res.sendStatus(200);
    }

    // ---------- /revokeinvite ----------
    if (/^\/revokeinvite\b/i.test(text)) {
      const parts = text.split(/\s+/);
      const chat_id = parseChatId(parts);
      if (!chat_id) {
        const sent = await tg.sendMessage(chatId, 'Usage: /revokeinvite <chat_id>');
        await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
        return res.sendStatus(200);
      }
      try {
        const row = await SponsoredInviteLinks.getLink(chat_id);
        if (row) {
          try {
            await tg.revokeChatInviteLink(chat_id, row.invite_link);
          } catch (e) {
            console.warn('[ADMIN /revokeinvite warn]', e?.description || e);
          }
          await SponsoredInviteLinks.updateStatus(chat_id, 'revoked');

          const summary = [
            `✅ Invite revoked for <b>${esc(row.chat_title || chat_id)}</b>`,
            `Status set to <b>revoked</b> (row kept).`,
          ].join('\n');
          const sent = await sendHTML(summary);
          await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_OK);
        } else {
          const sent = await tg.sendMessage(chatId, 'Not found in DB.');
          await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
        }
      } catch (err) {
        console.error('[ADMIN /revokeinvite ERROR]', err);
        const sent = await tg.sendMessage(chatId, t?.(lang, 'GENERIC_ERROR') ?? 'Something went wrong.');
        await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
      }
      return res.sendStatus(200);
    }

    // ---------- /editinvite ----------
    if (/^\/editinvite\b/i.test(text)) {
      const parts = text.trim().split(/\s+/).slice(1); // drop cmd
      const args = parseArgs(parts);
      const chat_id = parseChatId(args._);

      if (!chat_id || Object.keys(args).filter(k => k !== '_').length === 0) {
        const sent = await tg.sendMessage(chatId, 'Usage: /editinvite <chat_id> limit=10 expire=3600 name="NewName"');
        await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
        return res.sendStatus(200);
      }

      try {
        const row = await SponsoredInviteLinks.getLink(chat_id);
        if (!row) {
          const sent = await tg.sendMessage(chatId, 'Not found in DB.');
          await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
          return res.sendStatus(200);
        }

        const params = {};
        if (args.limit) params.member_limit = parseInt(args.limit, 10);
        if (args.expire) params.expire_date = Math.floor(Date.now() / 1000) + parseInt(args.expire, 10);
        if (args.name) params.name = args.name;

        const resLink = await tg.editChatInviteLink(chat_id, row.invite_link, params);

        await SponsoredInviteLinks.addOrUpdateLink({
          chat_id,
          invite_link: resLink.invite_link,
          link_name: resLink.name ?? row.link_name ?? null,
          chat_title: row.chat_title,
          chat_username: row.chat_username,
          join_limit: resLink.member_limit ?? row.join_limit ?? null,
          expire_date: resLink.expire_date ? new Date(resLink.expire_date * 1000) : (args.expire ? new Date(Date.now() + parseInt(args.expire, 10) * 1000) : row.expire_date)
        });

        const summary = [
          `✅ Invite updated for <b>${esc(row.chat_title || chat_id)}</b>`,
          `Name: <code>${esc(resLink.name ?? row.link_name ?? '-')}</code>`,
          `Limit: <b>${resLink.member_limit ?? row.join_limit ?? '∞'}</b>`,
          `Expire: <b>${resLink.expire_date ? fmtDate(new Date(resLink.expire_date * 1000)) : (args.expire ? fmtSec(parseInt(args.expire, 10)) : (row.expire_date ? fmtDate(row.expire_date) : 'never'))}</b>`,
          `• If the invite URL changed, per-link joins reset to <b>0</b>.`,
        ].join('\n');

        const sent = await sendHTML(summary);
        await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_OK);
      } catch (err) {
        console.error('[ADMIN /editinvite ERROR]', err);
        const sent = await tg.sendMessage(chatId, t?.(lang, 'GENERIC_ERROR') ?? 'Something went wrong.');
        await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
      }
      return res.sendStatus(200);
    }

    // ---------- /inviteinfo ----------
    if (/^\/inviteinfo\b/i.test(text)) {
      const parts = text.split(/\s+/);
      const chat_id = parseChatId(parts);
      if (!chat_id) {
        const sent = await tg.sendMessage(chatId, 'Usage: /inviteinfo <chat_id>');
        await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
        return res.sendStatus(200);
      }
      try {
        const row = await SponsoredInviteLinks.getLink(chat_id);
        if (!row) {
          const sent = await tg.sendMessage(chatId, 'Not found in DB.');
          await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
          return res.sendStatus(200);
        }

        const info = [
          `<b>Invite Link Info</b>`,
          `Chat: <code>${esc(row.chat_title || row.chat_id)}</code>`,
          `Username: @${esc(row.chat_username || '-')}`,
          `Invite: <code>${esc(row.invite_link)}</code>`,
          `Name: <code>${esc(row.link_name || '-')}</code>`,
          `Status: <b>${esc(row.status)}</b>`,
          `Per-link joins: <b>${row.link_joins ?? 0}</b>`,
          `Remaining on this link: <b>${row.remaining_joins ?? '-'}</b>`,
          `Limit (this link): <b>${row.join_limit ?? '-'}</b>`,
          `Total joins (lifetime): <b>${row.total_joins ?? 0}</b>`,
          `Expire: <b>${row.expire_date ? fmtDate(row.expire_date) : '-'}</b>`,
          `Created: <b>${fmtDate(row.created_at)}</b>`,
          `Updated: <b>${fmtDate(row.updated_at)}</b>`,
          row.last_checked_at ? `Last checked: <b>${fmtDate(row.last_checked_at)}</b>` : '',
        ].filter(Boolean).join('\n');

        const sent = await sendHTML(info);
        await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_OK);
      } catch (err) {
        console.error('[ADMIN /inviteinfo ERROR]', err);
        const sent = await tg.sendMessage(chatId, t?.(lang, 'GENERIC_ERROR') ?? 'Something went wrong.');
        await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
      }
      return res.sendStatus(200);
    }

    // ---------- /invites ----------
    if (/^\/invites$/.test(text)) {
      try {
        const all = await SponsoredInviteLinks.getAllLinks();
        if (!Array.isArray(all) || !all.length) {
          const sent = await tg.sendMessage(chatId, 'No invites tracked.');
          await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
          return res.sendStatus(200);
        }

        const lines = all.map((row) => {
          const statusEmoji = row.status === 'in_progress' ? '🟢'
            : row.status === 'revoked' ? '🔴'
            : row.status === 'expired' ? '⏳'
            : row.status === 'finished' ? '✅'
            : '⚪️';

          const limit = row.join_limit ?? '∞';
          const rem = row.remaining_joins ?? '-';
          const linkJoins = row.link_joins ?? 0;
          const total = row.total_joins ?? 0;

          return [
            `${statusEmoji} <b>${esc(row.chat_title || row.chat_id)}</b>`,
            `@${esc(row.chat_username || '-')}`,
            `Link: <code>${esc(row.invite_link)}</code>`,
            `Per-link: ${linkJoins}/${limit} (remaining: ${rem})`,
            `Total: ${total}`,
            `Status: ${esc(row.status)} | Expire: ${row.expire_date ? fmtDate(row.expire_date) : '-'}`,
            `— — —`,
          ].join('\n');
        });

        const chunks = chunkMessages(lines, 3500); // keep margin for HTML
        for (const chunk of chunks) {
          const sent = await sendHTML(chunk);
          await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_OK);
        }
      } catch (err) {
        console.error('[ADMIN /invites ERROR]', err);
        const sent = await tg.sendMessage(chatId, t?.(lang, 'GENERIC_ERROR') ?? 'Something went wrong.');
        await react(tgQueue, tg, chatId, getMsgId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
      }
      return res.sendStatus(200);
    }
    if (/^\/queuestop$/.test(text)) {
      tgQueue.stop();
      const sent = await safeApiCall(tgQueue, tg, tg.sendMessage.bind(tg), [chatId, '✅ Queue stopped.'], chatId);
      await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.ADMIN_OK);
      return res.sendStatus(200);
    }

    if (/^\/queueresume$/.test(text)) {
      tgQueue.resume();
      const sent = await safeApiCall(tgQueue, tg, tg.sendMessage.bind(tg), [chatId, '✅ Queue resumed.'], chatId);
      await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.ADMIN_OK);
      return res.sendStatus(200);
    }

    if (/^\/adminhelp$/.test(text)) {
      const sent = await safeApiCall(
        tgQueue, tg,
        tg.sendMessage.bind(tg),
        [chatId, Admin.getAdminHelp(), { parse_mode: 'HTML' }],
        chatId
      );
      await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.ADMIN_OK);
      return res.sendStatus(200);
    }

    if (/^\/(cmds|cmdstat)$/.test(text)) {
      const stats = await Admin.getCommandsStats(20);
      if (!stats.length) {
        const sent = await safeApiCall(tgQueue, tg, tg.sendMessage.bind(tg), [chatId, 'No commands used yet.'], chatId);
        await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
      } else {
        const lines = stats.map((r, i) =>
          `${i+1}. <code>${r.command}</code> — <b>${r.uses}</b> times`
        );
        const sent = await safeApiCall(
          tgQueue, tg,
          tg.sendMessage.bind(tg),
          [chatId, lines.join('\n'), { parse_mode: 'HTML' }],
          chatId
        );
        await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.ADMIN_OK);
      }
      return res.sendStatus(200);
    }

    if (/^\/interactions\b/i.test(text)) {
      const n = parseInt(text.split(/\s+/)[1] || '10', 10);
      const rows = await Admin.getLastInteractions(n);
      if (!rows.length) {
        const sent = await safeApiCall(tgQueue, tg, tg.sendMessage.bind(tg), [chatId, 'No interactions found.'], chatId);
        await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
      } else {
        const lines = rows.map(r =>
          `[${new Date(r.created_at).toLocaleString()}] ${r.type}: ${r.payload?.slice(0,32)} (${r.user_id})`
        );
        const sent = await safeApiCall(tgQueue, tg, tg.sendMessage.bind(tg), [chatId, lines.join('\n')], chatId);
        await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.ADMIN_OK);
      }
      return res.sendStatus(200);
    }

    if (/^\/active$/.test(text)) {
      const rows = await Admin.getActiveUsers(5);
      if (!rows.length) {
        const sent = await safeApiCall(tgQueue, tg, tg.sendMessage.bind(tg), [chatId, 'No active users.'], chatId);
        await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
      } else {
        const lines = rows.map((r, i) =>
          `${i+1}. <code>${r.user_id}</code> — <b>${r.total}</b> actions`
        );
        const sent = await safeApiCall(
          tgQueue, tg,
          tg.sendMessage.bind(tg),
          [chatId, lines.join('\n'), { parse_mode: 'HTML' }],
          chatId
        );
        await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.ADMIN_OK);
      }
      return res.sendStatus(200);
    }

    if (/^\/buttons$/.test(text)) {
      const rows = await Admin.getTopButtons(5);
      if (!rows.length) {
        const sent = await safeApiCall(tgQueue, tg, tg.sendMessage.bind(tg), [chatId, 'No button clicks found.'], chatId);
        await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
      } else {
        const lines = rows.map((r, i) =>
          `${i+1}. <code>${r.button}</code> — <b>${r.clicks}</b> clicks`
        );
        const sent = await safeApiCall(
          tgQueue, tg,
          tg.sendMessage.bind(tg),
          [chatId, lines.join('\n'), { parse_mode: 'HTML' }],
          chatId
        );
        await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.ADMIN_OK);
      }
      return res.sendStatus(200);
    }

    if (/^\/msgs\b/.test(text)) {
      const n = parseInt(text.split(/\s+/)[1] || '10', 10);
      const msgs = await Admin.getLastUserMessages(n);
      if (!msgs.length) {
        const sent = await safeApiCall(tgQueue, tg, tg.sendMessage.bind(tg), [chatId, 'No messages found.'], chatId);
        await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.ADMIN_WARN);
      } else {
        const lines = msgs.map(m =>
          `[${new Date(m.created_at).toLocaleString()}] <b>${m.user_id}</b>: <code>${m.payload?.slice(0,40)}</code>`
        );
        const sent = await safeApiCall(
          tgQueue, tg,
          tg.sendMessage.bind(tg),
          [chatId, lines.join('\n'), { parse_mode: 'HTML' }],
          chatId
        );
        await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.ADMIN_OK);
      }
      return res.sendStatus(200);
    }

    if (/^\/clearinteractions$/.test(text)) {
      await Admin.clearInteractions();
      const sent = await safeApiCall(tgQueue, tg, tg.sendMessage.bind(tg), [chatId, 'All interactions cleared!'], chatId);
      await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.ADMIN_OK);
      return res.sendStatus(200);
    }

    if (/^\/test\b/i.test(text)) {
      const up = Math.floor((Date.now() - startedAt.getTime())/1000);
      const sent = await safeApiCall(
        tgQueue, tg,
        tg.sendMessage.bind(tg),
        [chatId, `✅ Bot is working!\nUptime: ${up} seconds.`],
        chatId,
        'Status unavailable'
      );
      await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.STATUS);
      if (getMessageId(sent)) {
        await UserStateManager.setState(fromId, chatId, 'status', {}, getMessageId(sent));
      }
      return res.sendStatus(200);
    }

    if (/^\/last(\s+\d+)?$/i.test(text)) {
      const n = parseInt((text.match(/^\/last\s+(\d+)$/i)||[])[1] || '5', 10);
      const msgs = await Admin.getLastUserMessages(n);
      const payload = msgs.length
        ? `Last ${msgs.length} messages:\n\n${msgs.map(m =>
            `[${new Date(m.created_at).toISOString().replace('T',' ').slice(0,19)}] ${m.user_id}: ${m.payload}`
          ).join('\n\n')}`
        : 'No recent messages.';
      const sent = await safeApiCall(
        tgQueue, tg,
        tg.sendMessage.bind(tg),
        [chatId, payload],
        chatId,
        'History unavailable'
      );
      await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.HISTORY);
      if (getMessageId(sent)) {
        await UserStateManager.setState(fromId, chatId, 'history', {}, getMessageId(sent));
      }
      return res.sendStatus(200);
    }

    if (/^\/menu$/.test(text)) {
      const sent = await safeApiCall(
        tgQueue, tg,
        tg.sendMessage.bind(tg),
        [chatId, t(lang, 'MENU_TITLE'), { reply_markup: { inline_keyboard: mainMenuButtons(lang) } }],
        chatId,
        'Menu unavailable'
      );
      const menuId = getMessageId(sent);
      if (menuId) {
        await UserStateManager.setState(fromId, chatId, 'menu', {}, menuId);
        await react(tgQueue, tg, chatId, menuId, MESSAGE_REACTIONS.MENU_SHOWN);
      }
      return res.sendStatus(200);
    }

    if (/^\/reset$/.test(text)) {
      await UserStateManager.deleteState(fromId, chatId);
      const sent = await safeApiCall(
        tgQueue, tg,
        tg.sendMessage.bind(tg),
        [chatId, t(lang, 'STATE_RESET')],
        chatId,
        'Reset failed'
      );
      await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.STATE_RESET);
      if (getMessageId(sent)) {
        await UserStateManager.setState(fromId, chatId, 'reset', {}, getMessageId(sent));
      }
      return res.sendStatus(200);
    }

    if (/^\/editlast$/.test(text)) {
      const st = await UserStateManager.getState(fromId, chatId);
      if (st?.last_message_id) {
        try {
          await safeApiCall(
            tgQueue, tg,
            tg.editMessageText.bind(tg),
            [chatId, st.last_message_id, t(lang, 'EDITED')],
            chatId,
            'Edit failed'
          );
          const confirm = await safeApiCall(
            tgQueue, tg,
            tg.sendMessage.bind(tg),
            [chatId, t(lang, 'EDITED_CONFIRM')],
            chatId,
            'Confirmation failed'
          );
          await react(tgQueue, tg, chatId, getMessageId(confirm), MESSAGE_REACTIONS.ADMIN_OK);
          if (getMessageId(confirm)) {
            await UserStateManager.setState(fromId, chatId, 'menu', {}, getMessageId(confirm));
          }
        } catch {
          await UserStateManager.deleteState(fromId, chatId);
        }
      } else {
        const noEdit = await safeApiCall(
          tgQueue, tg,
          tg.sendMessage.bind(tg),
          [chatId, t(lang, 'NO_EDITABLE')],
          chatId,
          'Nothing to edit'
        );
        await react(tgQueue, tg, chatId, getMessageId(noEdit), MESSAGE_REACTIONS.ADMIN_WARN);
        if (getMessageId(noEdit)) {
          await UserStateManager.setState(fromId, chatId, 'menu', {}, getMessageId(noEdit));
        }
      }
      return res.sendStatus(200);
    }

    if (/^\/deletelast$/.test(text)) {
      const st = await UserStateManager.getState(fromId, chatId);
      if (st?.last_message_id) {
        try {
          await safeApiCall(
            tgQueue, tg,
            tg.deleteMessage.bind(tg),
            [chatId, st.last_message_id],
            chatId,
            'Delete failed'
          );
          await UserStateManager.deleteState(fromId, chatId);
          const confirm = await safeApiCall(
            tgQueue, tg,
            tg.sendMessage.bind(tg),
            [chatId, t(lang, 'DELETED_CONFIRM')],
            chatId,
            'Confirmation failed'
          );
          await react(tgQueue, tg, chatId, getMessageId(confirm), MESSAGE_REACTIONS.ADMIN_OK);
          if (getMessageId(confirm)) {
            await UserStateManager.setState(fromId, chatId, 'menu', {}, getMessageId(confirm));
          }
        } catch {
          await UserStateManager.deleteState(fromId, chatId);
        }
      } else {
        const noDel = await safeApiCall(
          tgQueue, tg,
          tg.sendMessage.bind(tg),
          [chatId, t(lang, 'NO_DELETABLE')],
          chatId,
          'Nothing to delete'
        );
        await react(tgQueue, tg, chatId, getMessageId(noDel), MESSAGE_REACTIONS.ADMIN_WARN);
        if (getMessageId(noDel)) {
          await UserStateManager.setState(fromId, chatId, 'menu', {}, getMessageId(noDel));
        }
      }
      return res.sendStatus(200);
    }
  }

  // --- /start FLOW ---
  if (/^\/start$/.test(text)) {
    await react(tgQueue, tg, chatId, userMessageId, MESSAGE_REACTIONS.START_FLOW, { is_big: true });

    await UserStateManager.deleteState(fromId, chatId);
    if (isNewUser && ADMIN_ID_INT && fromId !== ADMIN_ID_INT) {
      const joined = userInfo?.joined_at
        ? new Date(userInfo.joined_at).toLocaleString()
        : '(unknown)';
      const info = [
        t('en', 'NEW_USER'),
        `ID: ${fromId}`,
        `Username: @${username}`,
        `Name: ${(msg.from.first_name || '') + ' ' + (msg.from.last_name || '')}`.trim(),
        `Language: ${msg.from.language_code || '-'}`,
        `Bot: ${msg.from.is_bot ? 'Yes' : 'No'}`,
        `Joined at: ${joined}`
      ].join('\n');
      await tg.sendMessage(ADMIN_ID_INT, info);
    }
    if (!userInfo.selected_lang) {
      const langButtons = LANG_NAMES.map(l => [{ text: l.name, callback_data: `lang_${l.code}` }]);
      const sent = await safeApiCall(
        tgQueue, tg,
        tg.sendMessage.bind(tg),
        [chatId, t('en', 'SELECT_LANG'), { reply_markup: { inline_keyboard: langButtons } }],
        chatId,
        'Sorry, something went wrong. Please try again later.'
      );
      await react(tgQueue, tg, chatId, getMessageId(sent), MESSAGE_REACTIONS.MENU_SHOWN);
      await UserStateManager.setState(fromId, chatId, 'lang_select', {}, getMessageId(sent));
      return res.sendStatus(200);
    }
    const menuSent = await safeApiCall(
      tgQueue, tg,
      tg.sendMessage.bind(tg),
      [chatId, t(lang, 'MENU_TITLE'), { reply_markup: { inline_keyboard: mainMenuButtons(lang) } }],
      chatId,
      'Sorry, something went wrong. Please try again later.'
    );
    const menuId = getMessageId(menuSent);
    await UserStateManager.setState(fromId, chatId, 'menu', {}, menuId);
    await react(tgQueue, tg, chatId, menuId, MESSAGE_REACTIONS.MENU_SHOWN);
    return res.sendStatus(200);
  }

  return res.sendStatus(200);
}
