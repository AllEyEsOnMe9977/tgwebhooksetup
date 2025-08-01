import express from 'express';
import * as dotenv from 'dotenv';
import { TelegramAPI } from './tg/api.js';
import { ensureTables } from './db/schema.js';
import { saveMessage, getLastMessages } from './db/message.js';

dotenv.config();

const { BOT_TOKEN, PORT, ADMIN_ID } = process.env;
const ADMIN_ID_INT = parseInt(ADMIN_ID, 10) || 0;
const app = express();
app.use(express.json());

const tg = new TelegramAPI(BOT_TOKEN);
const startedAt = new Date();

// Ensure DB schema on startup
await ensureTables();

app.post(`/bot${BOT_TOKEN}`, async (req, res) => {
  try {
    const update = req.body;
    if (update.message && update.message.text) {
      const msg = update.message;
      const chatId = msg.chat.id;
      const fromId = msg.from.id;
      const username = msg.from.username || '';
      const text = msg.text.trim();

      // Save all messages as usual
      await saveMessage(chatId, fromId, username, text);

      // Admin-only commands
      if (ADMIN_ID_INT && fromId === ADMIN_ID_INT) {
        if (/^\/test\b/i.test(text)) {
          const up = Math.floor((Date.now() - startedAt.getTime()) / 1000);
          await tg.sendMessage(chatId, `✅ Bot is working!\nUptime: ${up} seconds.`);
          return res.sendStatus(200);
        }

        if (/^\/last(\s+\d+)?$/i.test(text)) {
          const n = parseInt((text.match(/^\/last\s+(\d+)$/i) || [])[1] || "5", 10);
          const msgs = await getLastMessages(n);
          if (!msgs.length) {
            await tg.sendMessage(chatId, `No recent messages.`);
          } else {
            const out = msgs
              .map(m => `[${m.created_at.toISOString().replace('T', ' ').substring(0, 19)}] ${m.username || m.user_id}: ${m.text}`)
              .join('\n\n');
            await tg.sendMessage(chatId, `Last ${msgs.length} messages:\n\n${out}`);
          }
          return res.sendStatus(200);
        }
      }
    // Handle callback queries (inline buttons)
    if (update.callback_query) {
      const cq = update.callback_query;
      const user_id = Number(cq.from.id);
      const chat_id = Number(cq.message.chat.id);
      const message_id = Number(cq.message.message_id);
      const data = cq.data;

      if (data === 'to_submenu') {
        await UserStateManager.setState(user_id, chat_id, "submenu", { at: new Date() }, message_id);
        await tg.editMessageText(chat_id, message_id, "You are in the submenu.\n\nPress to go back.", {
          reply_markup: {
            inline_keyboard: [
              [{ text: "⬅️ Back to Main Menu", callback_data: "to_mainmenu" }]
            ]
          }
        });
        return res.sendStatus(200);
      }
      if (data === 'to_mainmenu') {
        await UserStateManager.setState(user_id, chat_id, "menu", {}, message_id);
        await tg.editMessageText(chat_id, message_id, "Main menu:\n\nChoose:", {
          reply_markup: {
            inline_keyboard: [
              [{ text: "Go to Submenu", callback_data: "to_submenu" }]
            ]
          }
        });
        return res.sendStatus(200);
      }

      await UserStateManager.setState(user_id, chat_id, "menu", { last_callback: data }, message_id);
      await tg.answerCallbackQuery(cq.id, { text: `Pressed: ${data}` });
      return res.sendStatus(200);
    }

    // Handle messages
    if (update.message && update.message.text) {
      const msg = update.message;
      const chatId = Number(msg.chat.id);
      const fromId = Number(msg.from.id);
      const username = msg.from.username || '';
      const text = msg.text.trim();

      await saveMessage(chatId, fromId, username, text);

      if (isAdmin(fromId)) {
        if (/^\/menu$/.test(text)) {
          const reply = await tg.sendMessage(chatId, "Main menu:\n\nChoose:", {
            reply_markup: {
              inline_keyboard: [
                [{ text: "Go to Submenu", callback_data: "to_submenu" }]
              ]
            }
          });
          await UserStateManager.setState(fromId, chatId, "menu", {}, reply.message_id ? Number(reply.message_id) : null);
          return res.sendStatus(200);
        }
        if (/^\/reset$/.test(text)) {
          await UserStateManager.deleteState(fromId, chatId);
          await tg.sendMessage(chatId, "State reset. Send /menu to start again.");
          return res.sendStatus(200);
        }
        if (/^\/editlast$/.test(text)) {
          const state = await UserStateManager.getState(fromId, chatId);
          if (state && state.last_message_id) {
            try {
              await tg.editMessageText(chatId, Number(state.last_message_id), "✏️ This message was edited via /editlast!");
              await tg.sendMessage(chatId, "Last menu message edited!");
            } catch (e) {
              await UserStateManager.deleteState(fromId, chatId); // Clean up possibly bad state
              if (String(e).includes('message to edit not found')) {
                await tg.sendMessage(chatId, "❗ Message to edit was already deleted or too old.");
              } else if (String(e).includes('message is not modified')) {
                await tg.sendMessage(chatId, "❗ Message is already up-to-date. Try changing content.");
              } else {
                await tg.sendMessage(chatId, "❗ Failed to edit message. (API error)");
              }
            }
          } else {
            await tg.sendMessage(chatId, "No recent menu message to edit.");
          }
          return res.sendStatus(200);
        }

        if (/^\/deletelast$/.test(text)) {
          const state = await UserStateManager.getState(fromId, chatId);
          if (state && state.last_message_id) {
            try {
              await tg.deleteMessage(chatId, Number(state.last_message_id));
              await UserStateManager.deleteState(fromId, chatId); // Clean up after delete
              await tg.sendMessage(chatId, "Last menu message deleted!");
            } catch (e) {
              await UserStateManager.deleteState(fromId, chatId);
              if (String(e).includes('message to delete not found')) {
                await tg.sendMessage(chatId, "❗ Message to delete was already deleted or too old.");
              } else {
                await tg.sendMessage(chatId, "❗ Failed to delete message. (API error)");
              }
            }
          } else {
            await tg.sendMessage(chatId, "No recent menu message to delete.");
          }
          return res.sendStatus(200);
        }
      }
      // Simple echo for everyone
      await tg.sendMessage(chatId, `👋 Hello! You said: "${text}"`);
    }
    res.sendStatus(200);
  } catch (err) {
    console.error("Webhook error:", err);
    res.sendStatus(500);
  }
});

app.use((req, res) => res.sendStatus(404));

app.listen(PORT, async () => {
  console.log(`Express listening on port ${PORT}`);
  // Notify admin
  if (ADMIN_ID_INT) {
    try {
      await tg.sendMessage(ADMIN_ID_INT, `🚀 Bot started at ${new Date().toISOString()}`);
    } catch (e) {}
  }
});
