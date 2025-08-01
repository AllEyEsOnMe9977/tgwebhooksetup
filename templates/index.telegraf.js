//index.telegraf.js
import express from 'express';
import { Telegraf } from 'telegraf';
import * as dotenv from 'dotenv';
dotenv.config();

const { BOT_TOKEN, PORT, WEBHOOK_DOMAIN, ADMIN_ID, DB_TYPE } = process.env;
if (!BOT_TOKEN || !WEBHOOK_DOMAIN || !PORT) {
  console.error('❌ Missing .env values.');
  process.exit(1);
}
const bot = new Telegraf(BOT_TOKEN);

bot.use((ctx, next) => {
  console.log('📥 Incoming update:', JSON.stringify(ctx.update, null, 2));
  return next();
});

bot.start(async ctx => {
  console.log('▶️ /start from', ctx.from.username || ctx.from.id);
  try {
    await ctx.reply('👋 Bot ready!');
  } catch (err) {
    console.error('Reply error:', err);
  }
});

if (ADMIN_ID && ADMIN_ID !== '0') {
  bot.telegram
    .sendMessage(ADMIN_ID, `🚀 Bot started at ${new Date().toISOString()}`)
    .catch(err => console.error('Admin notify error:', err));
}

const app = express();
app.use(express.json());

app.post(`/bot${BOT_TOKEN}`, bot.webhookCallback(`/bot${BOT_TOKEN}`));
app.use((req, res) => {
  console.warn(`⚠️ Unmatched ${req.method} ${req.path}`);
  res.sendStatus(404);
});

app.listen(PORT, () => {
  console.log(`⚡️ Express listening on port ${PORT}`);
});

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
