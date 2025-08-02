import { saveMessage } from '../db/message.js';
import { UserStateManager } from '../db/state.js';
import { UserManager } from '../db/user.js';
import { trackInteraction } from '../db/interaction.js';
import * as Admin from '../db/admin.js';
import { LANGS, LANG_NAMES, t } from '../i18n.js';

const { ADMIN_ID } = process.env;
const ADMIN_ID_INT = parseInt(ADMIN_ID, 10) || 0;
const startedAt = new Date();

function mainMenuButtons(lang) {
  return [
    [{ text: t(lang, "GOTO_SUBMENU"), callback_data: "to_submenu" }],
    [{ text: t(lang, "CHANGE_LANG"), callback_data: "change_lang" }]
  ];
}

export async function handleMessage({ update, tg, tgQueue, res }) {
  const msg = update.message;
  const chatId = Number(msg.chat.id);
  const fromId = Number(msg.from.id);
  const username = msg.from.username || '';
  const text = msg.text.trim();

  // Save message to DB
  await saveMessage(chatId, fromId, username, text);

  // Track interaction
  await trackInteraction({
    user_id: fromId,
    chat_id: chatId,
    type: text.startsWith('/') ? 'command' : 'text',
    payload: text,
    message_id: msg.message_id
  });

  // Upsert user and get info
  const isNewUser = await UserManager.upsertUser(msg.from);
  let userInfo = await UserManager.getUser(fromId);
  const lang = userInfo?.selected_lang || "en";

  // Helper for all bot API calls (with queue)
  async function safeApiCall(fn, args = [], fallbackText = null) {
    try {
      return await tgQueue.enqueue(fn, args, chatId);
    } catch (err) {
      const msg = String(err);
      if (
        msg.includes('message is not modified') ||
        msg.includes('message to delete not found')
      ) {
        return;
      }
      if (chatId && fallbackText) {
        try { await tgQueue.enqueue(tg.sendMessage.bind(tg), [chatId, fallbackText], chatId); } catch (_) {}
      }
    }
  }

  // --- Admin commands ---
  if (ADMIN_ID_INT && fromId === ADMIN_ID_INT) {
    // /qstat
    if (/^\/qstat$/.test(text)) {
      const stats = `Queue: ${tgQueue.queue.length}, Rate: ${tgQueue.currentRate.toFixed(2)}/sec`;
      await safeApiCall(tg.sendMessage.bind(tg), [chatId, stats]);
      return res.sendStatus(200);
    }
    // /adminhelp
    if (/^\/adminhelp$/.test(text)) {
      await safeApiCall(tg.sendMessage.bind(tg), [chatId, Admin.getAdminHelp(), { parse_mode: "HTML" }]);
      return res.sendStatus(200);
    }
    // /cmds or /cmdstat
    if (/^\/cmds$|^\/cmdstat$/.test(text)) {
      const stats = await Admin.getCommandsStats(20);
      if (!stats.length) {
        await safeApiCall(tg.sendMessage.bind(tg), [chatId, 'No commands used yet.']);
        return res.sendStatus(200);
      }
      const lines = stats.map((row, i) => `${i+1}. <code>${row.command}</code> — <b>${row.uses}</b> times`);
      await safeApiCall(tg.sendMessage.bind(tg), [chatId, lines.join('\n'), { parse_mode: "HTML" }]);
      return res.sendStatus(200);
    }
    // /interactions N
    if (/^\/interactions\b/i.test(text)) {
      const n = parseInt(text.split(/\s+/)[1] || 10, 10);
      const rows = await Admin.getLastInteractions(n);
      if (!rows.length) {
        await safeApiCall(tg.sendMessage.bind(tg), [chatId, 'No interactions found.']);
        return res.sendStatus(200);
      }
      const lines = rows.map(r =>
        `[${new Date(r.created_at).toLocaleString()}] ${r.type}: ${r.payload ? r.payload.slice(0, 32) : ''} (${r.user_id})`
      );
      await safeApiCall(tg.sendMessage.bind(tg), [chatId, lines.join('\n')]);
      return res.sendStatus(200);
    }
    // /active
    if (/^\/active$/.test(text)) {
      const rows = await Admin.getActiveUsers(5);
      if (!rows.length) {
        await safeApiCall(tg.sendMessage.bind(tg), [chatId, 'No active users.']);
        return res.sendStatus(200);
      }
      const lines = rows.map((r, i) => `${i+1}. <code>${r.user_id}</code> — <b>${r.total}</b> actions`);
      await safeApiCall(tg.sendMessage.bind(tg), [chatId, lines.join('\n'), { parse_mode: "HTML" }]);
      return res.sendStatus(200);
    }
    // /buttons
    if (/^\/buttons$/.test(text)) {
      const rows = await Admin.getTopButtons(5);
      if (!rows.length) {
        await safeApiCall(tg.sendMessage.bind(tg), [chatId, 'No button clicks found.']);
        return res.sendStatus(200);
      }
      const lines = rows.map((r, i) => `${i+1}. <code>${r.button}</code> — <b>${r.clicks}</b> clicks`);
      await safeApiCall(tg.sendMessage.bind(tg), [chatId, lines.join('\n'), { parse_mode: "HTML" }]);
      return res.sendStatus(200);
    }
    // /msgs N
    if (/^\/msgs\b/.test(text)) {
      const n = parseInt(text.split(/\s+/)[1] || 10, 10);
      const msgs = await Admin.getLastUserMessages(n);
      if (!msgs.length) {
        await safeApiCall(tg.sendMessage.bind(tg), [chatId, 'No messages found.']);
        return res.sendStatus(200);
      }
      const lines = msgs.map(m =>
        `[${new Date(m.created_at).toLocaleString()}] <b>${m.user_id}</b>: <code>${m.payload ? m.payload.slice(0, 40) : ''}</code>`
      );
      await safeApiCall(tg.sendMessage.bind(tg), [chatId, lines.join('\n'), { parse_mode: "HTML" }]);
      return res.sendStatus(200);
    }
    // /clearinteractions
    if (/^\/clearinteractions$/.test(text)) {
      await Admin.clearInteractions();
      await safeApiCall(tg.sendMessage.bind(tg), [chatId, 'All interactions cleared!']);
      return res.sendStatus(200);
    }
    // /test
    if (/^\/test\b/i.test(text)) {
      const up = Math.floor((Date.now() - startedAt.getTime()) / 1000);
      const sent = await safeApiCall(
        tg.sendMessage.bind(tg),
        [chatId, `✅ Bot is working!\nUptime: ${up} seconds.`],
        'Failed to send status.'
      );
      if (sent?.message_id) {
        await UserStateManager.setState(fromId, chatId, 'status', {}, sent.message_id);
      }
      return res.sendStatus(200);
    }
    // /last N
    if (/^\/last(\s+\d+)?$/i.test(text)) {
      const n = parseInt((text.match(/^\/last\s+(\d+)$/i) || [])[1] || '5', 10);
      const msgs = await Admin.getLastUserMessages(n);
      const payload = msgs.length
        ? `Last ${msgs.length} messages:\n\n` +
          msgs.map(m =>
            `[${new Date(m.created_at).toISOString().replace('T', ' ').slice(0, 19)}] ${m.user_id}: ${m.payload}`
          ).join('\n\n')
        : 'No recent messages.';
      const sent = await safeApiCall(
        tg.sendMessage.bind(tg),
        [chatId, payload],
        'Failed to retrieve history.'
      );
      if (sent?.message_id) {
        await UserStateManager.setState(fromId, chatId, 'history', {}, sent.message_id);
      }
      return res.sendStatus(200);
    }
    // /menu
    if (/^\/menu$/.test(text)) {
      const sent = await safeApiCall(
        tg.sendMessage.bind(tg),
        [chatId, t(lang, 'MENU_TITLE'), {
          reply_markup: { inline_keyboard: mainMenuButtons(lang) }
        }]
      );
      if (sent?.message_id) {
        await UserStateManager.setState(fromId, chatId, 'menu', {}, sent.message_id);
      }
      return res.sendStatus(200);
    }
    // /reset
    if (/^\/reset$/.test(text)) {
      await UserStateManager.deleteState(fromId, chatId);
      const sent = await safeApiCall(
        tg.sendMessage.bind(tg),
        [chatId, t(lang, 'STATE_RESET')],
        'Failed to confirm reset.'
      );
      if (sent?.message_id) {
        await UserStateManager.setState(fromId, chatId, 'reset', {}, sent.message_id);
      }
      return res.sendStatus(200);
    }
    // /editlast
    if (/^\/editlast$/.test(text)) {
      const state = await UserStateManager.getState(fromId, chatId);
      if (state?.last_message_id) {
        try {
          await safeApiCall(
            tg.editMessageText.bind(tg),
            [chatId, Number(state.last_message_id), t(lang, 'EDITED')]
          );
          const sent = await safeApiCall(
            tg.sendMessage.bind(tg),
            [chatId, t(lang, 'EDITED_CONFIRM')],
            'Could not confirm edit.'
          );
          if (sent?.message_id) {
            await UserStateManager.setState(fromId, chatId, 'menu', {}, sent.message_id);
          }
        } catch {
          await UserStateManager.deleteState(fromId, chatId);
        }
      } else {
        const sent = await safeApiCall(
          tg.sendMessage.bind(tg),
          [chatId, t(lang, 'NO_EDITABLE')]
        );
        if (sent?.message_id) {
          await UserStateManager.setState(fromId, chatId, 'menu', {}, sent.message_id);
        }
      }
      return res.sendStatus(200);
    }
    // /deletelast
    if (/^\/deletelast$/.test(text)) {
      const state = await UserStateManager.getState(fromId, chatId);
      if (state?.last_message_id) {
        try {
          await safeApiCall(
            tg.deleteMessage.bind(tg),
            [chatId, Number(state.last_message_id)]
          );
          await UserStateManager.deleteState(fromId, chatId);
          const sent = await safeApiCall(
            tg.sendMessage.bind(tg),
            [chatId, t(lang, 'DELETED_CONFIRM')],
            'Could not confirm deletion.'
          );
          if (sent?.message_id) {
            await UserStateManager.setState(fromId, chatId, 'menu', {}, sent.message_id);
          }
        } catch {
          await UserStateManager.deleteState(fromId, chatId);
        }
      } else {
        const sent = await safeApiCall(
          tg.sendMessage.bind(tg),
          [chatId, t(lang, 'NO_DELETABLE')]
        );
        if (sent?.message_id) {
          await UserStateManager.setState(fromId, chatId, 'menu', {}, sent.message_id);
        }
      }
      return res.sendStatus(200);
    }
    // ... add more admin commands as needed ...
  }

  // /start: prompt for lang if needed, else show main menu
  if (/^\/start$/.test(text)) {
    if (isNewUser && ADMIN_ID_INT && fromId !== ADMIN_ID_INT) {
      const joined = userInfo && userInfo.joined_at
        ? new Date(userInfo.joined_at).toLocaleString()
        : '(unknown)';
      let info = [
        t("en", "NEW_USER"),
        `ID: ${fromId}`,
        `Username: @${username}`,
        `Name: ${msg.from.first_name || ''} ${msg.from.last_name || ''}`.trim(),
        `Language: ${msg.from.language_code || '-'}`,
        `Bot: ${msg.from.is_bot ? "Yes" : "No"}`,
        `Joined at: ${joined}`
      ].join('\n');
      await safeApiCall(tg.sendMessage.bind(tg), [ADMIN_ID_INT, info]);
    }
    if (!userInfo.selected_lang) {
      const langButtons = LANG_NAMES.map(l => [
        { text: l.name, callback_data: `lang_${l.code}` }
      ]);
      const sent = await tgQueue.enqueue(tg.sendMessage.bind(tg), [chatId, t("en", "SELECT_LANG"), {
        reply_markup: { inline_keyboard: langButtons }
      }], chatId);
      await UserStateManager.setState(fromId, chatId, 'lang_select', {}, sent.message_id);
      return res.sendStatus(200);
    }
    const sent = await tgQueue.enqueue(tg.sendMessage.bind(tg), [chatId, t(lang, "MENU_TITLE"), {
      reply_markup: { inline_keyboard: mainMenuButtons(lang) }
    }], chatId);
    await UserStateManager.setState(fromId, chatId, 'menu', {}, sent.message_id);
    return res.sendStatus(200);
  }

  // Fallback: echo
  const sent = await safeApiCall(
    tg.sendMessage.bind(tg),
    [chatId, t(lang, "ECHO", { text })]
  );
  if (sent?.message_id) {
    await UserStateManager.setState(fromId, chatId, 'echo', {}, sent.message_id);
  }
  return res.sendStatus(200);
}
