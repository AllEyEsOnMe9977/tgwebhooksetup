// index.js
import express from 'express';
import * as dotenv from 'dotenv';
import { ensureTables } from './db/schema.js';
import { TelegramAPI } from './tg/api.js';
import { TelegramQueue } from './tg/queue.js';
import { handleMessage } from './handlers/messageHandler.js';
import { handleCallback } from './handlers/callbackHandler.js';

dotenv.config();

// ----- Load Environment Variables -----
const { BOT_TOKEN, PORT } = process.env;
if (!BOT_TOKEN || !PORT) {
  console.error('FATAL: Missing BOT_TOKEN or PORT in .env');
  process.exit(1);
}

// ----- Initialize Telegram API and Queue -----
const tg = new TelegramAPI(BOT_TOKEN);

const tgQueue = new TelegramQueue({ 
  initialRate: 25, 
  minRate: 3, 
  maxRate: 28,
  maxConcurrent: 20  // New parameter
});

// Let the queue resolve function names (e.g., "sendMessage") after restarts
tgQueue.registerContext('tg', tg);

// ----- Prepare Express App -----
const app = express();
app.use(express.json());

// ----- Ensure Database Tables -----
await ensureTables();

// ----- Telegram Webhook Handler -----
app.post(`/bot${BOT_TOKEN}`, async (req, res) => {
  const update = req.body;
  try {
    if (update.callback_query) {
      await handleCallback({ update, tg, tgQueue, res });
    } else if (update.message && update.message.text) {
      await handleMessage({ update, tg, tgQueue, res });
    } else {
      res.sendStatus(200); // ignore other update types
    }
  } catch (err) {
    console.error('Webhook error:', err);
    res.sendStatus(500);
  }
});

// ----- Fallback for All Other Routes -----
app.use((req, res) => res.sendStatus(404));

// ----- Start Express Server -----
app.listen(PORT, () => {
  console.log(`Express listening on port ${PORT}`);
});
