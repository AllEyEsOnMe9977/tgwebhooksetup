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
