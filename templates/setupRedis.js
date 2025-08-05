// setupRedis.js
// Interactive Redis setup/doctor for your bot.
// Place this file next to package.json and run with: node setupRedis.js [command]
//
// Commands:
//   wizard          - Interactive setup: diagnose, secure, enable AOF, update .env, test
//   doctor          - Checks connectivity, auth, ACL user, AOF
//   set-requirepass - Sets/changes 'requirepass' and persists via CONFIG REWRITE
//   create-acl      - Creates a least-privilege ACL user (recommended) and ACL SAVE
//   enable-aof      - Enables Append-Only File persistence and persists
//   set-env         - Updates/creates REDIS_URL in .env (keeps a backup)
//   test            - Tests connection with current REDIS_URL
//
// Env use:
//   - Reads REDIS_URL from .env if present; otherwise defaults to redis://127.0.0.1:6379/0
//
// NOTE: For server config changes (requirepass, enable-aof, ACL), you must connect as an admin user.
//       If you're not currently authenticated as an admin, the script will prompt for the admin password.

import * as dotenv from 'dotenv';
import fs from 'fs';
import path from 'path';
import readline from 'readline/promises';
import { stdin as input, stdout as output } from 'node:process';
import Redis from 'ioredis';
import { fileURLToPath } from 'url';

dotenv.config();

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ENV_PATH = path.join(__dirname, '.env');
const ENV_BAK_PATH = path.join(__dirname, `.env.bak.${Date.now()}`);

const MASK = (s) => (s ? s.replace(/.(?=.{4})/g, '•') : '');
const enc = (s) => encodeURIComponent(s ?? '');
const dec = (s) => decodeURIComponent(s ?? '');
const isLocal = (url) => /^redis(s)?:\/\/[^@]*@?127\.0\.0\.1(:\d+)?/i.test(url) || /^redis(s)?:\/\/[^@]*@?localhost(:\d+)?/i.test(url);

// Resolve current URL (fallback to local)
function currentRedisUrl() {
  return process.env.REDIS_URL?.trim() || 'redis://127.0.0.1:6379/0';
}

// Parse a redis://[user:pass@]host:port/db into parts
function parseRedisUrl(url) {
  try {
    const u = new URL(url);
    const user = u.username ? dec(u.username) : '';
    const pass = u.password ? dec(u.password) : '';
    const db = u.pathname && u.pathname !== '/' ? Number(u.pathname.slice(1)) : 0;
    return { scheme: u.protocol.replace(':', ''), user, pass, host: u.hostname, port: Number(u.port || 6379), db, raw: url };
  } catch {
    return null;
  }
}

function buildRedisUrl({ scheme = 'redis', user = '', pass = '', host = '127.0.0.1', port = 6379, db = 0 }) {
  const creds = user || pass ? `${enc(user)}:${enc(pass)}@` : '';
  return `${scheme}://${creds}${host}:${port}/${db}`;
}

async function connect(url, opts = {}) {
  const redis = new Redis(url, {
    connectTimeout: 5000,
    maxRetriesPerRequest: null,
    ...opts,
  });
  try {
    await redis.ping();
    return redis;
  } catch (e) {
    redis.disconnect();
    throw e;
  }
}

async function ensureAdmin(redis, urlParts) {
  // Try an admin-only command to verify privileges.
  try {
    await redis.config('GET', 'requirepass'); // admin-only
    return true;
  } catch {
    // Ask for admin password and re-connect as default admin user (no username, just password auth)
    const rl = readline.createInterface({ input, output });
    const adminPass = await rl.question('Enter admin password for Redis (default user): ', { hideEchoBack: true });
    await rl.close();
    const adminUrl = buildRedisUrl({ ...urlParts, user: '', pass: adminPass });
    const r2 = await connect(adminUrl);
    // small check again
    await r2.config('GET', 'requirepass');
    redis.disconnect();
    return r2;
  }
}

async function doctor() {
  const url = currentRedisUrl();
  const parts = parseRedisUrl(url);
  console.log('🔎 Using REDIS_URL:', url.replace(parts?.pass || '', MASK(parts?.pass || '')));

  try {
    const redis = await connect(url);
    const whoami = await redis.call('ACL', 'WHOAMI').catch(() => 'unknown');
    let infoPersistence = '';
    try {
      const info = await redis.info('persistence');
      infoPersistence = info;
    } catch {}

    let requirepass = '<unknown>';
    let aofEnabled = '<unknown>';
    try {
      const cfg = await redis.config('GET', 'requirepass');
      requirepass = Array.isArray(cfg) ? (cfg[1] ? 'SET' : 'NOT SET') : '<unknown>';
      const aof = await redis.config('GET', 'appendonly');
      aofEnabled = Array.isArray(aof) ? (aof[1] === 'yes' ? 'ENABLED' : 'DISABLED') : '<unknown>';
    } catch {
      // Not admin; leave as unknown
    }

    console.log('✅ Connectivity: PING ok');
    console.log('👤 ACL user:', whoami);
    console.log('🔐 requirepass:', requirepass);
    console.log('💾 AOF:', aofEnabled);
    if (infoPersistence.includes('aof_enabled:1')) {
      console.log('   (info) aof_enabled:1 confirmed via INFO');
    }

    redis.disconnect();
    return true;
  } catch (e) {
    console.error('❌ Doctor failed:', e.message);
    return false;
  }
}

async function setRequirepass() {
  const url = currentRedisUrl();
  const parts = parseRedisUrl(url);
  if (!parts) throw new Error('Invalid REDIS_URL');

  const redis = await connect(url).catch(() => null);
  const adminRedis = redis ? await ensureAdmin(redis, parts) : await ensureAdmin(new Redis(), parts);

  const rl = readline.createInterface({ input, output });
  const pw = await rl.question('New requirepass (will be stored in redis.conf via CONFIG REWRITE): ', { hideEchoBack: true });
  await rl.close();

  try {
    await adminRedis.config('SET', 'requirepass', pw);
    await adminRedis.config('REWRITE');
    console.log('✅ requirepass set and persisted.');
    const newUrl = buildRedisUrl({ ...parts, user: '', pass: pw });
    console.log('➡  Use this REDIS_URL (URL-encoded):');
    console.log('   ', buildRedisUrl({ ...parts, user: '', pass: pw })); // buildRedisUrl encodes automatically
    adminRedis.disconnect();
  } catch (e) {
    adminRedis.disconnect();
    throw e;
  }
}

async function createAclUser() {
  const url = currentRedisUrl();
  const parts = parseRedisUrl(url);
  if (!parts) throw new Error('Invalid REDIS_URL');

  const redis = await connect(url).catch(() => null);
  const adminRedis = redis ? await ensureAdmin(redis, parts) : await ensureAdmin(new Redis(), parts);

  const rl = readline.createInterface({ input, output });
  const user = await rl.question('ACL username to create (e.g., tgbot): ');
  const pass = await rl.question(`Password for user "${user}": `, { hideEchoBack: true });
  await rl.close();

  const ACL_RULE = `${user} on >"${pass}" ~* +@all -@dangerous`; // broad, minus dangerous
  try {
    await adminRedis.call('ACL', 'SETUSER', ...ACL_RULE.split(' '));
    await adminRedis.call('ACL', 'SAVE');
    console.log(`✅ ACL user "${user}" created and saved.`);
    const newUrl = buildRedisUrl({ ...parts, user, pass });
    console.log('➡  Use this REDIS_URL (URL-encoded):');
    console.log('   ', newUrl);
    adminRedis.disconnect();
  } catch (e) {
    adminRedis.disconnect();
    throw e;
  }
}

async function enableAof() {
  const url = currentRedisUrl();
  const parts = parseRedisUrl(url);
  if (!parts) throw new Error('Invalid REDIS_URL');

  const redis = await connect(url).catch(() => null);
  const adminRedis = redis ? await ensureAdmin(redis, parts) : await ensureAdmin(new Redis(), parts);

  try {
    await adminRedis.config('SET', 'appendonly', 'yes');
    await adminRedis.config('REWRITE');
    console.log('✅ AOF enabled and persisted.');
    adminRedis.disconnect();
  } catch (e) {
    adminRedis.disconnect();
    throw e;
  }
}

async function setEnvUrl() {
  const url = currentRedisUrl();
  const parts = parseRedisUrl(url) || {};
  const rl = readline.createInterface({ input, output });

  const scheme = (await rl.question(`Scheme [redis/rediss] (${parts.scheme || 'redis'}): `)) || parts.scheme || 'redis';
  const host = (await rl.question(`Host (${parts.host || '127.0.0.1'}): `)) || parts.host || '127.0.0.1';
  const port = Number((await rl.question(`Port (${parts.port || 6379}): `)) || parts.port || 6379);
  const user = await rl.question(`Username (leave blank for default user): `);
  const pass = await rl.question(`Password (leave blank for none): `, { hideEchoBack: true });
  const db = Number((await rl.question(`DB index (${parts.db ?? 0}): `)) || (parts.db ?? 0));

  await rl.close();

  const newUrl = buildRedisUrl({ scheme, host, port, user, pass, db });
  console.log('➡  New REDIS_URL:', newUrl.replace(pass, MASK(pass)));

  // Write to .env (backup first)
  try {
    if (fs.existsSync(ENV_PATH)) fs.copyFileSync(ENV_PATH, ENV_BAK_PATH);
    let content = fs.existsSync(ENV_PATH) ? fs.readFileSync(ENV_PATH, 'utf-8') : '';
    if (/^REDIS_URL=/m.test(content)) {
      content = content.replace(/^REDIS_URL=.*$/m, `REDIS_URL=${newUrl}`);
    } else {
      content += (content.endsWith('\n') ? '' : '\n') + `REDIS_URL=${newUrl}\n`;
    }
    fs.writeFileSync(ENV_PATH, content, 'utf-8');
    console.log(`✅ .env updated (backup at ${path.basename(ENV_BAK_PATH)})`);
  } catch (e) {
    console.error('❌ Failed to update .env:', e.message);
  }
}

async function testConn() {
  const url = currentRedisUrl();
  try {
    const r = await connect(url);
    const whoami = await r.call('ACL', 'WHOAMI').catch(() => 'unknown');
    console.log('✅ PING ok. User:', whoami);
    r.disconnect();
  } catch (e) {
    console.error('❌ Test failed:', e.message);
    process.exitCode = 1;
  }
}

async function wizard() {
  console.log('=== Redis Setup Wizard ===');
  await doctor();

  const rl = readline.createInterface({ input, output });
  const choice = (await rl.question(
    '\nChoose security method:\n' +
    '  [1] Use requirepass on default user (simple)\n' +
    '  [2] Create ACL user (recommended)\n' +
    '  [s] Skip security step\n' +
    'Your choice: '
  )).trim().toLowerCase();

  try {
    if (choice === '1') await setRequirepass();
    else if (choice === '2') await createAclUser();
    else console.log('↩  Skipped security setup.');
  } catch (e) {
    console.error('❌ Security step failed:', e.message);
  }

  const aof = (await rl.question('\nEnable AOF persistence? [Y/n] ')).trim().toLowerCase();
  if (aof !== 'n') {
    try { await enableAof(); } catch (e) { console.error('❌ AOF step failed:', e.message); }
  } else {
    console.log('↩  Skipped AOF.');
  }

  const env = (await rl.question('\nUpdate .env REDIS_URL now? [Y/n] ')).trim().toLowerCase();
  if (env !== 'n') {
    await setEnvUrl();
    console.log('ℹ  Restart your app: pm2 restart tg-bot-20250801 --update-env');
  } else {
    console.log('↩  Skipped .env update.');
  }

  await rl.close();

  console.log('\nFinal check:');
  await testConn();
  console.log('\n🎉 Wizard completed.');
}

// ---------------- CLI Entrypoint ----------------
const cmd = (process.argv[2] || 'wizard').toLowerCase();

(async () => {
  try {
    switch (cmd) {
      case 'wizard':        await wizard(); break;
      case 'doctor':        await doctor(); break;
      case 'set-requirepass': await setRequirepass(); break;
      case 'create-acl':    await createAclUser(); break;
      case 'enable-aof':    await enableAof(); break;
      case 'set-env':       await setEnvUrl(); break;
      case 'test':          await testConn(); break;
      default:
        console.log(`
Usage: node setupRedis.js [command]

Commands:
  wizard           Interactive setup (diagnose → secure → AOF → update .env → test)
  doctor           Connectivity & config check (auth, ACL user, AOF)
  set-requirepass  Set/replace requirepass and persist (CONFIG REWRITE)
  create-acl       Create least-privilege ACL user and persist (ACL SAVE)
  enable-aof       Enable AOF persistence and persist (CONFIG REWRITE)
  set-env          Edit or add REDIS_URL in .env (with URL-encoding)
  test             PING and ACL WHOAMI using current REDIS_URL

Examples:
  node setupRedis.js                # Run the wizard
  node setupRedis.js doctor         # Quick health check
  node setupRedis.js create-acl     # Make a tgbot user
  node setupRedis.js set-requirepass
  node setupRedis.js enable-aof
  node setupRedis.js set-env
  node setupRedis.js test
`); }
  } catch (e) {
    console.error('❌ Error:', e.message);
    process.exitCode = 1;
  }
})();
