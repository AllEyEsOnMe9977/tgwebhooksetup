import TelegramBot from 'node-telegram-bot-api';
import express from 'express';
import * as dotenv from 'dotenv';
dotenv.config();

const { BOT_TOKEN, PORT, ADMIN_ID, DB_TYPE } = process.env;
const app = express();
app.use(express.json());

const bot = new TelegramBot(BOT_TOKEN, { webHook: { port: PORT } });
bot.onText(/\/start/, msg => bot.sendMessage(msg.chat.id, '👋 Bot ready!'));
if (ADMIN_ID && ADMIN_ID !== '0') bot.sendMessage(ADMIN_ID, '🚀 Bot started');

export default bot;

app.post(`/bot${BOT_TOKEN}`, (req, res) => { bot.processUpdate(req.body); res.sendStatus(200); });
app.use((req, res) => res.sendStatus(404));
app.listen(PORT, () => console.log(`Bot is listening on port ${PORT}`));

/* --- MariaDB integration (optional) --- */
if (DB_TYPE === "mariadb") {
  (async () => {
    try {
      const { testDb } = await import('./db.js');
      const latest = await testDb();
      console.log("✅ MariaDB test success! Latest row:", latest);
    } catch (e) {
      console.error("❌ MariaDB integration failed:", e);
    }
  })();
}
