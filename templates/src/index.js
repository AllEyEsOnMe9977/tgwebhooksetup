import express from 'express';
import * as dotenv from 'dotenv';
import { TelegramAPI } from './tg/api.js';
import { ensureTables } from './db/schema.js';
import { saveMessage } from './db/message.js';

dotenv.config();

const { BOT_TOKEN, PORT, ADMIN_ID } = process.env;
const app = express();
app.use(express.json());

const tg = new TelegramAPI(BOT_TOKEN);

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
      const text = msg.text;

      console.log(`[MSG] from ${username || fromId}: ${text}`);
      await saveMessage(chatId, fromId, username, text);

      // Example: Simple echo
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
  if (ADMIN_ID && ADMIN_ID !== "0") {
    try {
      await tg.sendMessage(ADMIN_ID, `🚀 Bot started at ${new Date().toISOString()}`);
    } catch (e) {}
  }
});
