import express from 'express';
import * as dotenv from 'dotenv';
import { ensureTables } from './db/schema.js';
import { TelegramAPI } from './tg/api.js';
import { TelegramQueue } from './tg/queue.js';
import { handleMessage } from './handlers/messageHandler.js';
import { handleCallback } from './handlers/callbackHandler.js';

dotenv.config();

const { BOT_TOKEN, PORT } = process.env;
const tg = new TelegramAPI(BOT_TOKEN);
const tgQueue = new TelegramQueue({ initialRate: 25, minRate: 3, maxRate: 28 });

const app = express();
app.use(express.json());

await ensureTables();

app.post(`/bot${BOT_TOKEN}`, async (req, res) => {
  const update = req.body;
  try {
    if (update.callback_query) {
      await handleCallback({ update, tg, tgQueue, res });
    } else if (update.message && update.message.text) {
      await handleMessage({ update, tg, tgQueue, res });
    } else {
      res.sendStatus(200);
    }
  } catch (err) {
    console.error('Webhook error:', err);
    res.sendStatus(500);
  }
});

app.use((req, res) => res.sendStatus(404));

app.listen(PORT, () => {
  console.log(`Express listening on port ${PORT}`);
});
