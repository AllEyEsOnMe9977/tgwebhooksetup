import express from 'express';
import * as dotenv from 'dotenv';
import { TelegramAPI } from './tg/api.js';
import { ensureTables } from './db/schema.js';
import { saveMessage, getLastMessages } from './db/message.js';
import { UserStateManager } from './db/state.js';
import { UserManager } from './db/user.js';
import { LANGS, LANG_NAMES, t } from './i18n.js';

dotenv.config();

const { BOT_TOKEN, PORT, ADMIN_ID } = process.env;
const ADMIN_ID_INT = parseInt(ADMIN_ID, 10) || 0;
const app = express();
app.use(express.json());

const tg = new TelegramAPI(BOT_TOKEN);
const startedAt = new Date();

function mainMenuButtons(lang) {
  return [
    [{ text: t(lang, "GOTO_SUBMENU"), callback_data: "to_submenu" }],
    [{ text: t(lang, "CHANGE_LANG"), callback_data: "change_lang" }]
  ];
}

// Helper: safe API call with error/retry handling
async function safeApiCall(fn, args = [], chatId = null, fallbackText = null) {
  try {
    return await fn(...args);
  } catch (err) {
    const msg = String(err);
    const m = msg.match(/retry after (\d+)/i);
    if (m) {
      const wait = Number(m[1]);
      console.warn(`[Telegram] Rate limited, retrying after ${wait}s…`);
      await new Promise(r => setTimeout(r, wait * 1000));
      return safeApiCall(fn, args, chatId, fallbackText);
    }
    if (
      msg.includes('message is not modified') ||
      msg.includes('message to delete not found')
    ) {
      console.info('[Telegram] No-op:', msg);
      return;
    }
    console.error('[Telegram] API error:', err);
    if (chatId && fallbackText) {
      try { await tg.sendMessage(chatId, fallbackText); } catch (_) {}
    }
  }
}

await ensureTables();

app.post(`/bot${BOT_TOKEN}`, async (req, res) => {
  try {
    const update = req.body;

    // ─── Handle callback queries (inline buttons) ──────────────
    if (update.callback_query) {
      const cq = update.callback_query;
      const userId = Number(cq.from.id);
      const chatId = Number(cq.message.chat.id);
      const messageId = Number(cq.message.message_id);
      const data = cq.data;
      const userInfo = await UserManager.getUser(userId);
      const lang = userInfo?.selected_lang || "en";

      // Language selection via inline buttons
      if (data.startsWith("lang_")) {
        const langCode = data.replace("lang_", "");
        if (LANGS.includes(langCode)) {
          await UserManager.setUserLang(userId, langCode);
          await safeApiCall(
            tg.editMessageText.bind(tg),
            [chatId, messageId, t(langCode, "LANG_SELECTED", { lang: t(langCode, "LANG_NAME") })]
          );
          setTimeout(async () => {
            await safeApiCall(
              tg.editMessageText.bind(tg),
              [chatId, messageId, t(langCode, "MENU_TITLE"), {
                reply_markup: { inline_keyboard: mainMenuButtons(langCode) }
              }]
            );
          }, 800);
          await safeApiCall(tg.answerCallbackQuery.bind(tg), [cq.id]);
          return res.sendStatus(200);
        }
      }

      // Change language button
      if (data === 'change_lang') {
        const langButtons = LANG_NAMES.map(l => [
          { text: l.name, callback_data: `lang_${l.code}` }
        ]);
        await safeApiCall(
          tg.editMessageText.bind(tg),
          [chatId, messageId, t(lang, "LANG_MENU"), {
            reply_markup: { inline_keyboard: langButtons }
          }]
        );
        await safeApiCall(tg.answerCallbackQuery.bind(tg), [cq.id]);
        return res.sendStatus(200);
      }

      // Submenu logic
      if (data === 'to_submenu' || data === 'to_mainmenu') {
        if (data === 'to_submenu') {
          await UserStateManager.setState(userId, chatId, 'submenu', { at: new Date() }, messageId);
          await safeApiCall(
            tg.editMessageText.bind(tg),
            [chatId, messageId, t(lang, 'SUBMENU_TITLE'), {
              reply_markup: { inline_keyboard: [[{ text: t(lang, 'BACK_BUTTON'), callback_data: 'to_mainmenu' }]] }
            }]
          );
        } else if (data === 'to_mainmenu') {
          await UserStateManager.setState(userId, chatId, 'menu', {}, messageId);
          await safeApiCall(
            tg.editMessageText.bind(tg),
            [chatId, messageId, t(lang, 'MENU_TITLE'), {
              reply_markup: { inline_keyboard: mainMenuButtons(lang) }
            }]
          );
        }
        await safeApiCall(
          tg.answerCallbackQuery.bind(tg),
          [cq.id],
          chatId
        );
        return res.sendStatus(200);
      }

      // generic callback
      await UserStateManager.setState(userId, chatId, 'menu', { last_callback: data }, messageId);
      await safeApiCall(
        tg.answerCallbackQuery.bind(tg),
        [cq.id, { text: `Pressed: ${data}` }],
        chatId
      );
      return res.sendStatus(200);
    }

    // ─── Handle incoming messages ──────────────────────────────
    if (update.message && update.message.text) {
      const msg = update.message;
      const chatId = Number(msg.chat.id);
      const fromId = Number(msg.from.id);
      const username = msg.from.username || '';
      const text = msg.text.trim();

      // Save message to DB
      await saveMessage(chatId, fromId, username, text);

      // Upsert user and get current user info
      const isNewUser = await UserManager.upsertUser(msg.from);
      let userInfo = await UserManager.getUser(fromId);
      const lang = userInfo?.selected_lang || "en";

      // Admin-only commands
      if (ADMIN_ID_INT && fromId === ADMIN_ID_INT) {
        // /test
        if (/^\/test\b/i.test(text)) {
          const up = Math.floor((Date.now() - startedAt.getTime()) / 1000);
          await safeApiCall(
            tg.sendMessage.bind(tg),
            [chatId, `✅ Bot is working!\nUptime: ${up} seconds.`],
            chatId,
            'Failed to send status.'
          );
          return res.sendStatus(200);
        }

        // /last N
        if (/^\/last(\s+\d+)?$/i.test(text)) {
          const n = parseInt((text.match(/^\/last\s+(\d+)$/i) || [])[1] || '5', 10);
          const msgs = await getLastMessages(n);
          const payload = msgs.length
            ? `Last ${msgs.length} messages:\n\n` +
              msgs.map(m =>
                `[${m.created_at.toISOString().replace('T', ' ').slice(0, 19)}] ${m.username || m.user_id}: ${m.text}`
              ).join('\n\n')
            : 'No recent messages.';
          await safeApiCall(
            tg.sendMessage.bind(tg),
            [chatId, payload],
            chatId,
            'Failed to retrieve history.'
          );
          return res.sendStatus(200);
        }

        // /menu
        if (/^\/menu$/.test(text)) {
          const reply = await safeApiCall(
            tg.sendMessage.bind(tg),
            [chatId, t(lang, 'MENU_TITLE'), {
              reply_markup: { inline_keyboard: mainMenuButtons(lang) }
            }],
            chatId,
            'Failed to open menu.'
          );
          const mid = reply?.message_id ? Number(reply.message_id) : null;
          await UserStateManager.setState(fromId, chatId, 'menu', {}, mid);
          return res.sendStatus(200);
        }

        // /reset
        if (/^\/reset$/.test(text)) {
          await UserStateManager.deleteState(fromId, chatId);
          await safeApiCall(
            tg.sendMessage.bind(tg),
            [chatId, t(lang, 'STATE_RESET')],
            chatId,
            'Failed to confirm reset.'
          );
          return res.sendStatus(200);
        }

        // /editlast
        if (/^\/editlast$/.test(text)) {
          const state = await UserStateManager.getState(fromId, chatId);
          if (state?.last_message_id) {
            try {
              await safeApiCall(
                tg.editMessageText.bind(tg),
                [chatId, Number(state.last_message_id), t(lang, 'EDITED')],
                chatId
              );
              await safeApiCall(
                tg.sendMessage.bind(tg),
                [chatId, t(lang, 'EDITED_CONFIRM')],
                chatId,
                'Could not confirm edit.'
              );
            } catch {
              await UserStateManager.deleteState(fromId, chatId);
            }
          } else {
            await safeApiCall(
              tg.sendMessage.bind(tg),
              [chatId, t(lang, 'NO_EDITABLE')],
              chatId,
              null
            );
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
                [chatId, Number(state.last_message_id)],
                chatId
              );
              await UserStateManager.deleteState(fromId, chatId);
              await safeApiCall(
                tg.sendMessage.bind(tg),
                [chatId, t(lang, 'DELETED_CONFIRM')],
                chatId,
                'Could not confirm deletion.'
              );
            } catch {
              await UserStateManager.deleteState(fromId, chatId);
            }
          } else {
            await safeApiCall(
              tg.sendMessage.bind(tg),
              [chatId, t(lang, 'NO_DELETABLE')],
              chatId,
              null
            );
          }
          return res.sendStatus(200);
        }
      }

      // /start: prompt for lang if needed, else show main menu
      if (/^\/start$/.test(text)) {
        if (isNewUser && ADMIN_ID_INT && fromId !== ADMIN_ID_INT) {
          // Notify admin about new user
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
          await safeApiCall(
            tg.sendMessage.bind(tg),
            [ADMIN_ID_INT, info]
          );
        }

        // Show inline lang selector if not set
        if (!userInfo.selected_lang) {
          const langButtons = LANG_NAMES.map(l => [
            { text: l.name, callback_data: `lang_${l.code}` }
          ]);
          const sent = await tg.sendMessage(chatId, t("en", "SELECT_LANG"), {
            reply_markup: { inline_keyboard: langButtons }
          });
          await UserStateManager.setState(fromId, chatId, 'lang_select', {}, sent.message_id);
          return res.sendStatus(200);
        }

        // Else, show main menu in their language
        await tg.sendMessage(chatId, t(lang, "MENU_TITLE"), {
          reply_markup: { inline_keyboard: mainMenuButtons(lang) }
        });
        return res.sendStatus(200);
      }

      // Fallback: echo
      await safeApiCall(
        tg.sendMessage.bind(tg),
        [chatId, t(lang, "ECHO", { text })],
        chatId,
        null
      );
      return res.sendStatus(200);
    }

    res.sendStatus(200);
  } catch (err) {
    console.error('Webhook error:', err);
    res.sendStatus(500);
  }
});

app.use((req, res) => res.sendStatus(404));

app.listen(PORT, async () => {
  console.log(`Express listening on port ${PORT}`);
  if (ADMIN_ID_INT) {
    await safeApiCall(
      tg.sendMessage.bind(tg),
      [ADMIN_ID_INT, t("en", "BOT_STARTED", { time: new Date().toISOString() })]
    );
  }
});
