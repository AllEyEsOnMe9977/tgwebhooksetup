//setWebhook.js
import fetch from 'node-fetch';
import * as dotenv from 'dotenv';
dotenv.config();
const { BOT_TOKEN, WEBHOOK_DOMAIN } = process.env;
const setHookURL = `https://api.telegram.org/bot${BOT_TOKEN}/setWebhook?url=${WEBHOOK_DOMAIN}/bot${BOT_TOKEN}`;
const res = await fetch(setHookURL);
console.log(await res.json());
