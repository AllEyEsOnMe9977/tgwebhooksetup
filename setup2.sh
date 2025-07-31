#!/usr/bin/env bash
###############################################################################
# new-tg-bot.sh — Telegram Bot Setup Script (robust, reliable, repeatable)
# Author: You!
# Version: 2.1 (2025-07-31) - Added Database Integration
###############################################################################
set -euo pipefail
IFS=$'\n\t'

VER="2.1"
NODE_LTS="lts/*"
NGINX_SITE_DIR=/etc/nginx/sites-available
NGINX_SITE_LINK=/etc/nginx/sites-enabled
COLOR_OK="\e[32m"; COLOR_WARN="\e[33m"; COLOR_ERR="\e[31m"; COLOR_CLEAR="\e[0m"

msg()   { printf "%b[INFO ]%b %s\n"  "$COLOR_OK"   "$COLOR_CLEAR" "$*";  }
warn()  { printf "%b[WARN ]%b %s\n"  "$COLOR_WARN" "$COLOR_CLEAR" "$*"; }
die()   { printf "%b[ERROR]%b %s\n"  "$COLOR_ERR"  "$COLOR_CLEAR" "$*"; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Run as root (use sudo)."; }
command_exists() { command -v "$1" &>/dev/null; }
pause() { read -rp "Press <Enter> to continue … "; }
validate_domain() { local d=$1; [[ $d =~ ^https://[a-zA-Z0-9.-]+$ ]]; }
validate_token() { local t=$1; [[ $t =~ ^[0-9]{6,10}:[A-Za-z0-9_-]{35}$ ]]; }
generate_password() { openssl rand -base64 32 | tr -d "=+/" | cut -c1-16; }

need_root
msg "🌐  Telegram Bot Bootstrapper v$VER"
echo "Answer the following questions. Default values are shown in [brackets]."

read -rp "1) Telegram bot token: " BOT_TOKEN
validate_token "$BOT_TOKEN" || die "Token format invalid."

default_domain="https://$(hostname -f)"
read -rp "2) Public HTTPS domain for webhook [$default_domain]: " WEBHOOK_DOMAIN
WEBHOOK_DOMAIN=${WEBHOOK_DOMAIN:-$default_domain}
validate_domain "$WEBHOOK_DOMAIN" || die "Domain format invalid (MUST start with https://)"

read -rp "3) Numeric Telegram admin user ID (optional): " ADMIN_ID
ADMIN_ID=${ADMIN_ID:-0}

default_folder="tg-bot-$(date +%Y%m%d)"
read -rp "4) Project folder name [$default_folder]: " PROJECT_DIR
PROJECT_DIR=${PROJECT_DIR:-$default_folder}
PROJECT_PATH="/opt/$PROJECT_DIR"

echo "5) Choose Telegram library:"
select LIBRARY in "node-telegram-bot-api (official)" "Telegraf" "Quit"; do
    case $REPLY in
        1) LIBRARY_SLUG="telegram-api"; break ;;
        2) LIBRARY_SLUG="telegraf"; break ;;
        *) die "Aborted."; ;;
    esac
done

echo "6) Choose Database:"
select DATABASE in "MongoDB" "MariaDB" "MySQL" "None" "Quit"; do
    case $REPLY in
        1) DB_TYPE="mongodb"; break ;;
        2) DB_TYPE="mariadb"; break ;;
        3) DB_TYPE="mysql"; break ;;
        4) DB_TYPE="none"; break ;;
        *) die "Aborted."; ;;
    esac
done

# Database configuration
if [[ $DB_TYPE != "none" ]]; then
    default_db_name="${PROJECT_DIR}_db"
    read -rp "7) Database name [$default_db_name]: " DB_NAME
    DB_NAME=${DB_NAME:-$default_db_name}
    
    default_db_user="${PROJECT_DIR}_user"
    read -rp "8) Database username [$default_db_user]: " DB_USER
    DB_USER=${DB_USER:-$default_db_user}
    
    DB_PASSWORD=$(generate_password)
    read -rp "9) Database password [auto-generated: $DB_PASSWORD]: " INPUT_PASSWORD
    DB_PASSWORD=${INPUT_PASSWORD:-$DB_PASSWORD}
    
    if [[ $DB_TYPE != "mongodb" ]]; then
        read -rp "10) Database host [localhost]: " DB_HOST
        DB_HOST=${DB_HOST:-localhost}
        
        if [[ $DB_TYPE == "mariadb" ]]; then
            read -rp "11) Database port [3306]: " DB_PORT
            DB_PORT=${DB_PORT:-3306}
        elif [[ $DB_TYPE == "mysql" ]]; then
            read -rp "11) Database port [3306]: " DB_PORT
            DB_PORT=${DB_PORT:-3306}
        fi
    else
        read -rp "10) MongoDB connection host [localhost]: " DB_HOST
        DB_HOST=${DB_HOST:-localhost}
        read -rp "11) MongoDB port [27017]: " DB_PORT
        DB_PORT=${DB_PORT:-27017}
    fi
fi

read -rp "Custom port for Node.js (default 3000): " PORT
PORT=${PORT:-3000}

msg "Summary
────────────────────────────────
  Bot token         : $BOT_TOKEN
  Webhook domain    : $WEBHOOK_DOMAIN
  Admin user ID     : $ADMIN_ID
  Project directory : $PROJECT_PATH
  Library           : $LIBRARY_SLUG
  Database          : $DB_TYPE
  Node.js port      : $PORT"

if [[ $DB_TYPE != "none" ]]; then
    echo "  Database name     : $DB_NAME
  Database user     : $DB_USER
  Database password : $DB_PASSWORD
  Database host     : $DB_HOST
  Database port     : $DB_PORT"
fi

echo "────────────────────────────────"
pause

# ----------- SYSTEM SETUP ----------- #
msg "Updating system packages …"
apt-get update -qq && apt-get dist-upgrade -y -qq

if ! command_exists curl; then apt-get install -y -qq curl; fi
if ! command_exists gnupg; then apt-get install -y -qq gnupg ca-certificates; fi

msg "Installing Node.js $NODE_LTS …"
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y -qq nodejs build-essential

msg "Installing PM2 globally …"
npm install -g pm2 >/dev/null

msg "Installing / upgrading Nginx …"
apt-get install -y -qq nginx

msg "Installing Certbot …"
apt-get install -y -qq certbot python3-certbot-nginx

# ----------- DATABASE SETUP ----------- #
if [[ $DB_TYPE == "mongodb" ]]; then
    msg "Installing MongoDB …"
    curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-7.0.list
    apt-get update -qq
    apt-get install -y -qq mongodb-org
    systemctl enable mongod
    systemctl start mongod
    
    msg "Creating MongoDB user and database …"
    sleep 3  # Wait for MongoDB to start
    mongosh --eval "
    use admin;
    db.createUser({
      user: 'admin',
      pwd: '$DB_PASSWORD',
      roles: ['userAdminAnyDatabase', 'readWriteAnyDatabase']
    });
    use $DB_NAME;
    db.createUser({
      user: '$DB_USER',
      pwd: '$DB_PASSWORD',
      roles: ['readWrite']
    });
    " || warn "MongoDB user creation may have failed - check manually"

elif [[ $DB_TYPE == "mariadb" ]]; then
    msg "Installing MariaDB …"
    apt-get install -y -qq mariadb-server mariadb-client
    systemctl enable mariadb
    systemctl start mariadb
    
    msg "Securing MariaDB installation …"
    mysql_secure_installation --use-default
    
    msg "Creating MariaDB user and database …"
    mysql -u root -e "
    CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;
    CREATE USER IF NOT EXISTS '$DB_USER'@'$DB_HOST' IDENTIFIED BY '$DB_PASSWORD';
    GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'$DB_HOST';
    FLUSH PRIVILEGES;
    " || die "MariaDB user/database creation failed"

elif [[ $DB_TYPE == "mysql" ]]; then
    msg "Installing MySQL …"
    apt-get install -y -qq mysql-server mysql-client
    systemctl enable mysql
    systemctl start mysql
    
    msg "Securing MySQL installation …"
    mysql_secure_installation --use-default
    
    msg "Creating MySQL user and database …"
    mysql -u root -e "
    CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;
    CREATE USER IF NOT EXISTS '$DB_USER'@'$DB_HOST' IDENTIFIED BY '$DB_PASSWORD';
    GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'$DB_HOST';
    FLUSH PRIVILEGES;
    " || die "MySQL user/database creation failed"
fi

# ----------- PROJECT SCAFFOLD ----------- #
msg "Creating project at $PROJECT_PATH …"
mkdir -p "$PROJECT_PATH"
cd "$PROJECT_PATH"

# Create .env file
cat > .env <<EOF
# ========== Generated $(date -Iseconds) ==========
BOT_TOKEN="$BOT_TOKEN"
WEBHOOK_DOMAIN="$WEBHOOK_DOMAIN"
PORT=$PORT
ADMIN_ID=$ADMIN_ID
EOF

if [[ $DB_TYPE != "none" ]]; then
    cat >> .env <<EOF

# Database Configuration
DB_TYPE="$DB_TYPE"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASSWORD="$DB_PASSWORD"
DB_HOST="$DB_HOST"
DB_PORT=$DB_PORT
EOF
    
    if [[ $DB_TYPE == "mongodb" ]]; then
        echo "DB_CONNECTION_STRING=\"mongodb://$DB_USER:$DB_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME\"" >> .env
    else
        echo "DB_CONNECTION_STRING=\"mysql://$DB_USER:$DB_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME\"" >> .env
    fi
fi

chmod 600 .env

cat > package.json <<'EOF'
{ "name": "telegram-bot", "version": "1.0.0", "type": "module",
  "scripts": { "start": "node src/index.js", "sethook": "node setWebhook.js" } }
EOF

mkdir -p src

# Install database packages
if [[ $DB_TYPE == "mongodb" ]]; then
    npm i mongodb
elif [[ $DB_TYPE == "mariadb" || $DB_TYPE == "mysql" ]]; then
    npm i mysql2
fi

# Create db.js file
if [[ $DB_TYPE != "none" ]]; then
    msg "Creating database integration file …"
    
    if [[ $DB_TYPE == "mongodb" ]]; then
        cat > src/db.js <<'EOF'
import { MongoClient } from 'mongodb';
import * as dotenv from 'dotenv';
dotenv.config();

const { DB_CONNECTION_STRING, DB_NAME } = process.env;

let client;
let db;

export async function connectDB() {
    try {
        client = new MongoClient(DB_CONNECTION_STRING);
        await client.connect();
        db = client.db(DB_NAME);
        console.log('✅ Connected to MongoDB');
        
        // Create test collection and insert sample data
        await initializeTestData();
        return db;
    } catch (error) {
        console.error('❌ MongoDB connection failed:', error);
        throw error;
    }
}

export async function closeDB() {
    if (client) {
        await client.close();
        console.log('🔌 MongoDB connection closed');
    }
}

async function initializeTestData() {
    const users = db.collection('users');
    const testUser = await users.findOne({ userId: 'test_user' });
    
    if (!testUser) {
        await users.insertOne({
            userId: 'test_user',
            username: 'test_user',
            firstName: 'Test',
            lastName: 'User',
            createdAt: new Date(),
            isActive: true
        });
        console.log('📊 Test user data initialized in MongoDB');
    }
}

// User management functions
export async function createUser(userData) {
    const users = db.collection('users');
    const result = await users.insertOne({
        ...userData,
        createdAt: new Date(),
        isActive: true
    });
    return result;
}

export async function getUser(userId) {
    const users = db.collection('users');
    return await users.findOne({ userId: userId.toString() });
}

export async function updateUser(userId, updateData) {
    const users = db.collection('users');
    return await users.updateOne(
        { userId: userId.toString() },
        { $set: { ...updateData, updatedAt: new Date() } }
    );
}

export async function deleteUser(userId) {
    const users = db.collection('users');
    return await users.deleteOne({ userId: userId.toString() });
}

export async function getAllUsers() {
    const users = db.collection('users');
    return await users.find({ isActive: true }).toArray();
}

// Test database connection
export async function testConnection() {
    try {
        const users = db.collection('users');
        const count = await users.countDocuments();
        console.log(`📊 Database test successful. Users collection has ${count} documents.`);
        return true;
    } catch (error) {
        console.error('❌ Database test failed:', error);
        return false;
    }
}
EOF

    else  # MySQL/MariaDB
        cat > src/db.js <<'EOF'
import mysql from 'mysql2/promise';
import * as dotenv from 'dotenv';
dotenv.config();

const { DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME } = process.env;

let connection;

export async function connectDB() {
    try {
        connection = await mysql.createConnection({
            host: DB_HOST,
            port: parseInt(DB_PORT),
            user: DB_USER,
            password: DB_PASSWORD,
            database: DB_NAME
        });
        
        console.log('✅ Connected to MySQL/MariaDB');
        
        // Create test table and insert sample data
        await initializeTestData();
        return connection;
    } catch (error) {
        console.error('❌ Database connection failed:', error);
        throw error;
    }
}

export async function closeDB() {
    if (connection) {
        await connection.end();
        console.log('🔌 Database connection closed');
    }
}

async function initializeTestData() {
    // Create users table if it doesn't exist
    await connection.execute(`
        CREATE TABLE IF NOT EXISTS users (
            id INT AUTO_INCREMENT PRIMARY KEY,
            user_id VARCHAR(50) UNIQUE NOT NULL,
            username VARCHAR(100),
            first_name VARCHAR(100),
            last_name VARCHAR(100),
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            is_active BOOLEAN DEFAULT TRUE
        )
    `);
    
    // Insert test user if not exists
    const [rows] = await connection.execute(
        'SELECT * FROM users WHERE user_id = ?',
        ['test_user']
    );
    
    if (rows.length === 0) {
        await connection.execute(`
            INSERT INTO users (user_id, username, first_name, last_name)
            VALUES (?, ?, ?, ?)
        `, ['test_user', 'test_user', 'Test', 'User']);
        console.log('📊 Test user data initialized in database');
    }
}

// User management functions
export async function createUser(userData) {
    const { userId, username, firstName, lastName } = userData;
    const [result] = await connection.execute(`
        INSERT INTO users (user_id, username, first_name, last_name)
        VALUES (?, ?, ?, ?)
    `, [userId, username, firstName, lastName]);
    return result;
}

export async function getUser(userId) {
    const [rows] = await connection.execute(
        'SELECT * FROM users WHERE user_id = ? AND is_active = TRUE',
        [userId.toString()]
    );
    return rows[0] || null;
}

export async function updateUser(userId, updateData) {
    const { username, firstName, lastName } = updateData;
    const [result] = await connection.execute(`
        UPDATE users SET username = ?, first_name = ?, last_name = ?
        WHERE user_id = ?
    `, [username, firstName, lastName, userId.toString()]);
    return result;
}

export async function deleteUser(userId) {
    const [result] = await connection.execute(
        'UPDATE users SET is_active = FALSE WHERE user_id = ?',
        [userId.toString()]
    );
    return result;
}

export async function getAllUsers() {
    const [rows] = await connection.execute(
        'SELECT * FROM users WHERE is_active = TRUE ORDER BY created_at DESC'
    );
    return rows;
}

// Test database connection
export async function testConnection() {
    try {
        const [rows] = await connection.execute('SELECT COUNT(*) as count FROM users');
        console.log(`📊 Database test successful. Users table has ${rows[0].count} records.`);
        return true;
    } catch (error) {
        console.error('❌ Database test failed:', error);
        return false;
    }
}
EOF
    fi
fi

# Create index.js with database integration
if [[ $LIBRARY_SLUG == "telegram-api" ]]; then
    npm i node-telegram-bot-api express dotenv
    
    if [[ $DB_TYPE != "none" ]]; then
        cat > src/index.js <<'EOF'
import TelegramBot from 'node-telegram-bot-api';
import express from 'express';
import * as dotenv from 'dotenv';
import { connectDB, closeDB, testConnection, createUser, getUser, getAllUsers } from './db.js';
dotenv.config();

const { BOT_TOKEN, PORT, ADMIN_ID } = process.env;
const app = express();
app.use(express.json());

// Initialize database connection
let dbReady = false;
connectDB().then(() => {
    dbReady = true;
    testConnection();
}).catch(console.error);

const bot = new TelegramBot(BOT_TOKEN, { webHook: { port: PORT }});

// Bot commands
bot.onText(/\/start/, async (msg) => {
    const userId = msg.from.id;
    const username = msg.from.username;
    const firstName = msg.from.first_name;
    const lastName = msg.from.last_name;
    
    try {
        if (dbReady) {
            // Check if user exists, if not create them
            let user = await getUser(userId);
            if (!user) {
                await createUser({
                    userId: userId.toString(),
                    username,
                    firstName,
                    lastName
                });
                console.log(`👤 New user created: ${firstName} ${lastName} (@${username})`);
            }
        }
        
        bot.sendMessage(msg.chat.id, '👋 Bot ready! Database is ' + (dbReady ? 'connected ✅' : 'disconnected ❌'));
    } catch (error) {
        console.error('Error in /start command:', error);
        bot.sendMessage(msg.chat.id, '👋 Bot ready! (Database error occurred)');
    }
});

bot.onText(/\/users/, async (msg) => {
    if (!dbReady) {
        return bot.sendMessage(msg.chat.id, '❌ Database not connected');
    }
    
    try {
        const users = await getAllUsers();
        if (users.length === 0) {
            return bot.sendMessage(msg.chat.id, '👥 No users found in database');
        }
        
        let message = `👥 Total users: ${users.length}\n\n`;
        users.slice(0, 10).forEach((user, index) => {
            const name = `${user.firstName || user.first_name || ''} ${user.lastName || user.last_name || ''}`.trim();
            const username = user.username ? `@${user.username}` : '';
            message += `${index + 1}. ${name} ${username}\n`;
        });
        
        if (users.length > 10) {
            message += `\n... and ${users.length - 10} more users`;
        }
        
        bot.sendMessage(msg.chat.id, message);
    } catch (error) {
        console.error('Error in /users command:', error);
        bot.sendMessage(msg.chat.id, '❌ Error fetching users');
    }
});

bot.onText(/\/dbtest/, async (msg) => {
    if (!dbReady) {
        return bot.sendMessage(msg.chat.id, '❌ Database not connected');
    }
    
    const result = await testConnection();
    bot.sendMessage(msg.chat.id, result ? '✅ Database test successful!' : '❌ Database test failed!');
});

if (ADMIN_ID && ADMIN_ID !== '0') {
    bot.sendMessage(ADMIN_ID, '🚀 Bot started with database integration');
}

export default bot;

app.post(`/bot${BOT_TOKEN}`, (req, res) => { bot.processUpdate(req.body); res.sendStatus(200); });
app.use((req, res) => res.sendStatus(404));

const server = app.listen(PORT, () => console.log(`Bot is listening on port ${PORT}`));

// Graceful shutdown
process.on('SIGINT', async () => {
    console.log('Shutting down gracefully...');
    server.close();
    await closeDB();
    process.exit(0);
});
EOF
    else
        cat > src/index.js <<'EOF'
import TelegramBot from 'node-telegram-bot-api';
import express from 'express';
import * as dotenv from 'dotenv';
dotenv.config();

const { BOT_TOKEN, PORT, ADMIN_ID } = process.env;
const app = express();
app.use(express.json());

const bot = new TelegramBot(BOT_TOKEN, { webHook: { port: PORT }});
bot.onText(/\/start/, msg => bot.sendMessage(msg.chat.id, '👋 Bot ready!'));
if (ADMIN_ID && ADMIN_ID !== '0') bot.sendMessage(ADMIN_ID, '🚀 Bot started');

export default bot;

app.post(`/bot${BOT_TOKEN}`, (req, res) => { bot.processUpdate(req.body); res.sendStatus(200); });
app.use((req, res) => res.sendStatus(404));
app.listen(PORT, () => console.log(`Bot is listening on port ${PORT}`));
EOF
    fi

else  # Telegraf
    npm i telegraf dotenv express
    
    if [[ $DB_TYPE != "none" ]]; then
        cat > src/index.js <<EOF
import express from 'express';
import { Telegraf } from 'telegraf';
import * as dotenv from 'dotenv';
import { connectDB, closeDB, testConnection, createUser, getUser, getAllUsers } from './db.js';
dotenv.config();

const { BOT_TOKEN, PORT, WEBHOOK_DOMAIN, ADMIN_ID } = process.env;
if (!BOT_TOKEN || !WEBHOOK_DOMAIN || !PORT) {
  console.error('❌ Missing .env values.');
  process.exit(1);
}

// Initialize database connection
let dbReady = false;
connectDB().then(() => {
    dbReady = true;
    testConnection();
}).catch(console.error);

const bot = new Telegraf(BOT_TOKEN);

// Debug logger: show all incoming updates
bot.use((ctx, next) => {
  console.log('📥 Incoming update:', JSON.stringify(ctx.update, null, 2));
  return next();
});

bot.start(async ctx => {
  console.log('▶️ /start from', ctx.from.username || ctx.from.id);
  const userId = ctx.from.id;
  const username = ctx.from.username;
  const firstName = ctx.from.first_name;
  const lastName = ctx.from.last_name;
  
  try {
    if (dbReady) {
      // Check if user exists, if not create them
      let user = await getUser(userId);
      if (!user) {
        await createUser({
          userId: userId.toString(),
          username,
          firstName,
          lastName
        });
        console.log(\`👤 New user created: \${firstName} \${lastName} (@\${username})\`);
      }
    }
    
    await ctx.reply('👋 Bot ready! Database is ' + (dbReady ? 'connected ✅' : 'disconnected ❌'));
  } catch (err) {
    console.error('Error in /start command:', err);
    await ctx.reply('👋 Bot ready! (Database error occurred)');
  }
});

bot.command('users', async ctx => {
  if (!dbReady) {
    return await ctx.reply('❌ Database not connected');
  }
  
  try {
    const users = await getAllUsers();
    if (users.length === 0) {
      return await ctx.reply('👥 No users found in database');
    }
    
    let message = \`👥 Total users: \${users.length}\\n\\n\`;
    users.slice(0, 10).forEach((user, index) => {
      const name = \`\${user.firstName || user.first_name || ''} \${user.lastName || user.last_name || ''}\`.trim();
      const username = user.username ? \`@\${user.username}\` : '';
      message += \`\${index + 1}. \${name} \${username}\\n\`;
    });
    
    if (users.length > 10) {
      message += \`\\n... and \${users.length - 10} more users\`;
    }
    
    await ctx.reply(message);
  } catch (error) {
    console.error('Error in /users command:', error);
    await ctx.reply('❌ Error fetching users');
  }
});

bot.command('dbtest', async ctx => {
  if (!dbReady) {
    return await ctx.reply('❌ Database not connected');
  }
  
  const result = await testConnection();
  await ctx.reply(result ? '✅ Database test successful!' : '❌ Database test failed!');
});

if (ADMIN_ID && ADMIN_ID !== '0') {
  bot.telegram
    .sendMessage(ADMIN_ID, \`🚀 Bot started with database integration at \${new Date().toISOString()}\`)
    .catch(err => console.error('Admin notify error:', err));
}

const app = express();
app.use(express.json());

app.post(\`/bot\${BOT_TOKEN}\`, bot.webhookCallback(\`/bot\${BOT_TOKEN}\`));
app.use((req, res) => {
  console.warn(\`⚠️ Unmatched \${req.method} \${req.path}\`);
  res.sendStatus(404);
});

const server = app.listen(PORT, () => {
  console.log(\`⚡️ Express listening on port \${PORT}\`);
});

// Graceful shutdown
process.on('SIGINT', async () => {
  console.log('Shutting down gracefully...');
  server.close();
  await closeDB();
  process.exit(0);
});
EOF
    else
        cat > src/index.js <<EOF
import express from 'express';
import { Telegraf } from 'telegraf';
import * as dotenv from 'dotenv';
dotenv.config();

const { BOT_TOKEN, PORT, WEBHOOK_DOMAIN, ADMIN_ID } = process.env;
if (!BOT_TOKEN || !WEBHOOK_DOMAIN || !PORT) {
  console.error('❌ Missing .env values.');
  process.exit(1);
}
const bot = new Telegraf(BOT_TOKEN);

// Debug logger: show all incoming updates
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
    .sendMessage(ADMIN_ID, \`🚀 Bot started at \${new Date().toISOString()}\`)
    .catch(err => console.error('Admin notify error:', err));
}

const app = express();
app.use(express.json());

app.post(\`/bot\${BOT_TOKEN}\`, bot.webhookCallback(\`/bot\${BOT_TOKEN}\`));
app.use((req, res) => {
  console.warn(\`⚠️ Unmatched \${req.method} \${req.path}\`);
  res.sendStatus(404);
});

app.listen(PORT, () => {
  console.log(\`⚡️ Express listening on port \${PORT}\`);
});
EOF
    fi
fi

cat > setWebhook.js <<'EOF'
import fetch from 'node-fetch';
import * as dotenv from 'dotenv';
dotenv.config();
const { BOT_TOKEN, WEBHOOK_DOMAIN } = process.env;
const setHookURL = `https://api.telegram.org/bot${BOT_TOKEN}/setWebhook?url=${WEBHOOK_DOMAIN}/bot${BOT_TOKEN}`;
const res = await fetch(setHookURL);
console.log(await res.json());
EOF
npm i node-fetch@3 dotenv >/dev/null

# ----------- 2-STAGE NGINX CONFIG FOR CERTBOT -----------
SITE_CONF="$NGINX_SITE_DIR/$PROJECT_DIR.conf"
# Remove any old configs for this domain/project
sudo rm -f "$NGINX_SITE_DIR/$PROJECT_DIR.conf" "$NGINX_SITE_LINK/$PROJECT_DIR.conf"
sudo rm -f "$NGINX_SITE_DIR/${WEBHOOK_DOMAIN#https://}.conf" "$NGINX_SITE_LINK/${WEBHOOK_DOMAIN#https://}.conf"

msg "Configuring Nginx (HTTP-only for Certbot)..."
cat > "$SITE_CONF" <<EOF
server {
    listen 80;
    server_name ${WEBHOOK_DOMAIN#https://};
    location / { return 200 "ok"; }
}
EOF
ln -sf "$SITE_CONF" "$NGINX_SITE_LINK/$PROJECT_DIR.conf"
nginx -t || { die "Nginx test failed (HTTP-only, pre-certbot)."; }
systemctl reload nginx

msg "Requesting Let's Encrypt certificate (HTTP-only stage) …"
certbot --nginx -d "${WEBHOOK_DOMAIN#https://}" --non-interactive --agree-tos -m admin@"${WEBHOOK_DOMAIN#https://}"

msg "Writing final HTTPS Nginx config …"
cat > "$SITE_CONF" <<EOF
server {
    listen 80;
    server_name ${WEBHOOK_DOMAIN#https://};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${WEBHOOK_DOMAIN#https://};

    ssl_certificate     /etc/letsencrypt/live/${WEBHOOK_DOMAIN#https://}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${WEBHOOK_DOMAIN#https://}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "strict-origin-when-cross-origin";

    location / {
        proxy_pass         http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}
EOF
nginx -t || { die "Nginx test failed (after certbot)."; }
systemctl reload nginx

# ----------- PM2 PROCESS MANAGEMENT -----------
read -rp "Start the bot now with PM2 and enable boot‑start? (Y/n): " PM2_START
PM2_START=${PM2_START,,}
if [[ $PM2_START != "n" ]]; then
    pm2 start src/index.js --name "$PROJECT_DIR" --watch --cwd "$PROJECT_PATH"
    pm2 save
    pm2 startup systemd -u "$(logname)" --hp "/home/$(logname)" >/dev/null
fi

# ----------- RUN sethook ONLY after all is ready -----------
msg "Registering webhook with Telegram (final step)…"
WEBHOOK_RESULT=$(npm run sethook 2>&1 || true)
echo "$WEBHOOK_RESULT"
if echo "$WEBHOOK_RESULT" | grep -q '"ok":true'; then
    msg "✅ Webhook successfully set!"
else
    warn "⚠️  Webhook registration failed. See above. Run again after DNS and HTTPS are fully ready:"
    echo "    npm run sethook"
fi

cat <<EOF

══════════════════════════════════════════════════════════════════════
✅  Setup complete!

Project path      : $PROJECT_PATH
Node.js port      : $PORT
Webhook URL       : $WEBHOOK_DOMAIN/bot$BOT_TOKEN
Nginx conf        : $SITE_CONF
.ENV file         : $(realpath .env)
PM2 process name  : $PROJECT_DIR
EOF

if [[ $DB_TYPE != "none" ]]; then
    cat <<EOF
Database type     : $DB_TYPE
Database name     : $DB_NAME
Database user     : $DB_USER
Database host     : $DB_HOST:$DB_PORT

Database Commands:
  • /start - Register user in database
  • /users - List all users (first 10)
  • /dbtest - Test database connection
EOF
fi

cat <<EOF

Next steps:
  • Edit src/index.js to add more bot logic.
  • Edit src/db.js to add more database functions.
  • If you change the domain or token, run "npm run sethook" again.
  • Use "pm2 logs $PROJECT_DIR" to follow live logs.
  • Use "pm2 restart $PROJECT_DIR" after code changes (auto‑reload if --watch).
  • Use "curl -vk -X POST \"$WEBHOOK_DOMAIN/bot$BOT_TOKEN\"" to test end-to-end.
EOF

if [[ $DB_TYPE == "mongodb" ]]; then
    cat <<EOF
  • MongoDB shell: mongosh -u $DB_USER -p $DB_PASSWORD --authenticationDatabase $DB_NAME $DB_NAME
EOF
elif [[ $DB_TYPE == "mariadb" || $DB_TYPE == "mysql" ]]; then
    cat <<EOF
  • Database shell: mysql -u $DB_USER -p$DB_PASSWORD -h $DB_HOST -P $DB_PORT $DB_NAME
EOF
fi

cat <<EOF

══════════════════════════════════════════════════════════════════════
EOF
exit 0
