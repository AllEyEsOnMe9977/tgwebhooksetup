import express from 'express';
import * as dotenv from 'dotenv';
import { TelegramAPI } from './tg/api.js';
import { ensureTables } from './db/schema.js';
import { saveMessage, getLastMessages } from './db/message.js';
import { UserStateManager } from './db/state.js';

dotenv.config();

const { BOT_TOKEN, PORT, ADMIN_ID } = process.env;
const ADMIN_ID_INT = parseInt(ADMIN_ID, 10) || 0;
const app = express();
app.use(express.json());

const tg = new TelegramAPI(BOT_TOKEN);
const startedAt = new Date();

// Helper to wrap any tg.* call in retry/fallback logic
async function safeApiCall(fn, args = [], chatId = null, fallbackText = null) {
  try {
    return await fn(...args);
  } catch (err) {
    const msg = String(err);

    // 1) Flood-wait: "retry after X" → wait and retry
    const m = msg.match(/retry after (\d+)/i);
    if (m) {
      const wait = Number(m[1]);
      console.warn(`[Telegram] Rate limited, retrying after ${wait}s…`);
      await new Promise(r => setTimeout(r, wait * 1000));
      return safeApiCall(fn, args, chatId, fallbackText);
    }

    // 2) Silently ignore some no-ops
    if (
      msg.includes('message is not modified') ||
      msg.includes('message to delete not found')
    ) {
      console.info('[Telegram] No-op:', msg);
      return;
    }

    // 3) All other errors—log and optionally notify
    console.error('[Telegram] API error:', err);
    if (chatId && fallbackText) {
      try {
        await tg.sendMessage(chatId, fallbackText);
      } catch (_) {
        // swallow
      }
    }
  }
}

// Ensure DB schema on startup
await ensureTables();

// Webhook endpoint
app.post(`/bot${BOT_TOKEN}`, async (req, res) => {
  try {
    const update = req.body;

    // ─── Handle callback queries ───────────────────────────────
    if (update.callback_query) {
      const cq = update.callback_query;
      const userId = Number(cq.from.id);
      const chatId = Number(cq.message.chat.id);
      const messageId = Number(cq.message.message_id);
      const data = cq.data;

      if (data === 'to_submenu') {
        await UserStateManager.setState(userId, chatId, 'submenu', { at: new Date() }, messageId);
        await safeApiCall(
          tg.editMessageText.bind(tg),
          [chatId, messageId, 'You are in the submenu.\n\nPress to go back.', {
            reply_markup: { inline_keyboard: [[{ text: '⬅️ Back to Main Menu', callback_data: 'to_mainmenu' }]] }
          }],
          chatId,
          'Could not update submenu view.'
        );
        await safeApiCall(
          tg.answerCallbackQuery.bind(tg),
          [cq.id],
          chatId
        );
        return res.sendStatus(200);
      }

      if (data === 'to_mainmenu') {
        await UserStateManager.setState(userId, chatId, 'menu', {}, messageId);
        await safeApiCall(
          tg.editMessageText.bind(tg),
          [chatId, messageId, 'Main menu:\n\nChoose:', {
            reply_markup: { inline_keyboard: [[{ text: 'Go to Submenu', callback_data: 'to_submenu' }]] }
          }],
          chatId,
          'Could not update main menu.'
        );
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

    // ─── Handle incoming messages ───────────────────────────────
    if (update.message && update.message.text) {
      const msg = update.message;
      const chatId = Number(msg.chat.id);
      const fromId = Number(msg.from.id);
      const username = msg.from.username || '';
      const text = msg.text.trim();

      // Save message
      await saveMessage(chatId, fromId, username, text);

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
            [chatId, 'Main menu:\n\nChoose:', {
              reply_markup: {
                inline_keyboard: [[{ text: 'Go to Submenu', callback_data: 'to_submenu' }]]
              }
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
            [chatId, 'State reset. Send /menu to start again.'],
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
                [chatId, Number(state.last_message_id), '✏️ This message was edited via /editlast!'],
                chatId
              );
              await safeApiCall(
                tg.sendMessage.bind(tg),
                [chatId, 'Last menu message edited!'],
                chatId,
                'Could not confirm edit.'
              );
            } catch {
              await UserStateManager.deleteState(fromId, chatId);
            }
          } else {
            await safeApiCall(
              tg.sendMessage.bind(tg),
              [chatId, 'No recent menu message to edit.'],
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
                [chatId, 'Last menu message deleted!'],
                chatId,
                'Could not confirm deletion.'
              );
            } catch {
              await UserStateManager.deleteState(fromId, chatId);
            }
          } else {
            await safeApiCall(
              tg.sendMessage.bind(tg),
              [chatId, 'No recent menu message to delete.'],
              chatId,
              null
            );
          }
          return res.sendStatus(200);
        }
      }

      // Simple echo for everyone else
      await safeApiCall(
        tg.sendMessage.bind(tg),
        [chatId, `👋 Hello! You said: "${text}"`],
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

// 404 handler
app.use((req, res) => res.sendStatus(404));

// Start Express
app.listen(PORT, async () => {
  console.log(`Express listening on port ${PORT}`);
  if (ADMIN_ID_INT) {
    await safeApiCall(
      tg.sendMessage.bind(tg),
      [ADMIN_ID_INT, `🚀 Bot started at ${new Date().toISOString()}`]
    );
  }
});
