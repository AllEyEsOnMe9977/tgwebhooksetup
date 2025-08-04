// setWebhook.js - Enhanced version of your original
import fetch from 'node-fetch';
import * as dotenv from 'dotenv';

dotenv.config();

const { BOT_TOKEN, WEBHOOK_DOMAIN } = process.env;

if (!BOT_TOKEN || !WEBHOOK_DOMAIN) {
  console.error('Missing BOT_TOKEN or WEBHOOK_DOMAIN in .env');
  process.exit(1);
}

const WEBHOOK_URL = `${WEBHOOK_DOMAIN}/bot${BOT_TOKEN}`;
const command = process.argv[2] || 'set';

// Your original simple webhook setup
async function setWebhook() {
  const setHookURL = `https://api.telegram.org/bot${BOT_TOKEN}/setWebhook?url=${WEBHOOK_URL}`;
  console.log('Setting webhook to:', WEBHOOK_URL);
  
  const res = await fetch(setHookURL);
  const result = await res.json();
  console.log(result);
  
  if (result.ok) {
    console.log('✅ Webhook set successfully!');
  } else {
    console.log('❌ Failed to set webhook');
  }
}

// Get current webhook info
async function getInfo() {
  const infoURL = `https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo`;
  
  const res = await fetch(infoURL);
  const result = await res.json();
  
  if (result.ok) {
    console.log('📋 Webhook Info:');
    console.log('URL:', result.result.url || 'Not set');
    console.log('Pending updates:', result.result.pending_update_count);
    console.log('Last error:', result.result.last_error_message || 'None');
    console.log('Max connections:', result.result.max_connections);
  } else {
    console.log('❌ Error:', result.description);
  }
}

// Delete webhook
async function deleteWebhook() {
  const deleteURL = `https://api.telegram.org/bot${BOT_TOKEN}/setWebhook?url=`;
  
  const res = await fetch(deleteURL);
  const result = await res.json();
  console.log(result);
  
  if (result.ok) {
    console.log('✅ Webhook deleted successfully!');
  } else {
    console.log('❌ Failed to delete webhook');
  }
}

// Enhanced webhook setup with options
async function setAdvanced() {
  const params = new URLSearchParams({
    url: WEBHOOK_URL,
    max_connections: 100,
    allowed_updates: JSON.stringify(['message', 'callback_query']),
    drop_pending_updates: true
  });
  
  const setHookURL = `https://api.telegram.org/bot${BOT_TOKEN}/setWebhook?${params}`;
  console.log('Setting advanced webhook to:', WEBHOOK_URL);
  
  const res = await fetch(setHookURL);
  const result = await res.json();
  console.log(result);
  
  if (result.ok) {
    console.log('✅ Advanced webhook set successfully!');
    console.log('- Max connections: 100');
    console.log('- Allowed updates: message, callback_query');
    console.log('- Dropped pending updates: yes');
  } else {
    console.log('❌ Failed to set webhook');
  }
}

// Run commands
switch (command) {
  case 'set':
    await setWebhook();
    break;
    
  case 'advanced':
    await setAdvanced();
    break;
    
  case 'info':
    await getInfo();
    break;
    
  case 'delete':
    await deleteWebhook();
    break;
    
  default:
    console.log(`
Usage: node setWebhook.js [command]

Commands:
  set      - Set webhook (default, same as your original)
  advanced - Set webhook with optimal settings for high concurrency
  info     - Show current webhook status
  delete   - Remove webhook

Environment variables:
  BOT_TOKEN       - Your bot token
  WEBHOOK_DOMAIN  - Your domain (e.g., https://yourdomain.com)

Examples:
  node setWebhook.js           # Your original behavior
  node setWebhook.js set       # Same as above
  node setWebhook.js advanced  # Optimized for concurrent processing
  node setWebhook.js info      # Check webhook status
  node setWebhook.js delete    # Remove webhook
    `);
}
