#!/bin/bash

# Telegram Bot Automated Setup Script
# Author: Auto-generated setup script
# Description: Comprehensive automation for Telegram bot deployment
# Version: 1.0.0

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/telegram_bot_setup.log"
SETUP_SUMMARY=""

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Print colored output
print_colored() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Print banner
print_banner() {
    clear
    print_colored "$CYAN" "
╔═══════════════════════════════════════════════════════════════╗
║                  TELEGRAM BOT SETUP SCRIPT                   ║
║                   Automated Deployment Tool                  ║
╚═══════════════════════════════════════════════════════════════╝
"
}

# Error handler
error_exit() {
    print_colored "$RED" "ERROR: $1"
    log "ERROR: $1"
    exit 1
}

# Success message
success_msg() {
    print_colored "$GREEN" "✓ $1"
    log "SUCCESS: $1"
}

# Info message
info_msg() {
    print_colored "$BLUE" "ℹ $1"
    log "INFO: $1"
}

# Warning message
warn_msg() {
    print_colored "$YELLOW" "⚠ $1"
    log "WARNING: $1"
}

# Validate bot token format
validate_bot_token() {
    local token=$1
    if [[ ! $token =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        return 1
    fi
    return 0
}

# Validate domain format
validate_domain() {
    local domain=$1
    if [[ ! $domain =~ ^https?://[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(/.*)?$ ]]; then
        return 1
    fi
    return 0
}

# Validate user ID (numeric)
validate_user_id() {
    local user_id=$1
    if [[ ! $user_id =~ ^[0-9]+$ ]]; then
        return 1
    fi
    return 0
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        warn_msg "Running as root. This is not recommended for security reasons."
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Check system requirements
check_system() {
    info_msg "Checking system requirements..."
    
    # Check OS
    if [[ ! -f /etc/os-release ]]; then
        error_exit "Cannot determine OS version"
    fi
    
    source /etc/os-release
    info_msg "Detected OS: $PRETTY_NAME"
    
    # Check if apt is available (Debian/Ubuntu)
    if ! command -v apt &> /dev/null; then
        error_exit "This script requires apt package manager (Debian/Ubuntu)"
    fi
    
    # Check internet connectivity
    if ! ping -c 1 google.com &> /dev/null; then
        error_exit "No internet connection available"
    fi
    
    success_msg "System requirements check passed"
}

# Collect user inputs
collect_inputs() {
    print_colored "$PURPLE" "
╔═══════════════════════════════════════════════════════════════╗
║                    CONFIGURATION SETUP                       ║
╚═══════════════════════════════════════════════════════════════╝
"
    
    # Bot Token
    while true; do
        read -p "Enter your Telegram Bot Token (from @BotFather): " BOT_TOKEN
        if validate_bot_token "$BOT_TOKEN"; then
            break
        else
            print_colored "$RED" "Invalid bot token format. Expected format: 123456789:ABCdefGHIjklMNOpqrSTUvwxyz"
        fi
    done
    
    # Webhook Domain
    while true; do
        read -p "Enter webhook domain (e.g., https://mybot.example.com): " WEBHOOK_DOMAIN
        if validate_domain "$WEBHOOK_DOMAIN"; then
            break
        else
            print_colored "$RED" "Invalid domain format. Must include protocol (http/https)"
        fi
    done
    
    # Extract domain for nginx and SSL
    DOMAIN=$(echo "$WEBHOOK_DOMAIN" | sed -E 's/https?:\/\/([^\/]+).*/\1/')
    
    # Admin User ID
    while true; do
        read -p "Enter admin Telegram User ID: " ADMIN_USER_ID
        if validate_user_id "$ADMIN_USER_ID"; then
            break
        else
            print_colored "$RED" "Invalid user ID. Must be numeric"
        fi
    done
    
    # Project Name
    while true; do
        read -p "Enter project folder name (default: telegram-bot): " PROJECT_NAME
        PROJECT_NAME=${PROJECT_NAME:-telegram-bot}
        if [[ $PROJECT_NAME =~ ^[a-zA-Z0-9_-]+$ ]]; then
            break
        else
            print_colored "$RED" "Invalid project name. Use only letters, numbers, hyphens, and underscores"
        fi
    done
    
    # Telegram API Library Choice
    print_colored "$CYAN" "
Select Telegram API Library:
1) Official Telegram Bot API (node-telegram-bot-api)
2) Telegraf (Modern framework)
3) Grammy (Type-safe framework)
"
    while true; do
        read -p "Choose library (1-3, default: 2): " API_CHOICE
        API_CHOICE=${API_CHOICE:-2}
        case $API_CHOICE in
            1) API_LIBRARY="node-telegram-bot-api"; break;;
            2) API_LIBRARY="telegraf"; break;;
            3) API_LIBRARY="grammy"; break;;
            *) print_colored "$RED" "Invalid choice. Please select 1, 2, or 3";;
        esac
    done
    
    # Server Port
    read -p "Enter server port (default: 3000): " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-3000}
    
    # Webhook Path
    read -p "Enter webhook path (default: /webhook): " WEBHOOK_PATH
    WEBHOOK_PATH=${WEBHOOK_PATH:-/webhook}
    
    # PM2 Setup
    read -p "Set up PM2 process manager? (Y/n): " SETUP_PM2
    SETUP_PM2=${SETUP_PM2:-Y}
    
    # SSL Setup
    read -p "Set up SSL certificate with Let's Encrypt? (Y/n): " SETUP_SSL
    SETUP_SSL=${SETUP_SSL:-Y}
    
    # Confirmation
    print_colored "$YELLOW" "
╔═══════════════════════════════════════════════════════════════╗
║                    CONFIGURATION SUMMARY                     ║
╚═══════════════════════════════════════════════════════════════╝
Project Name: $PROJECT_NAME
Domain: $DOMAIN
Webhook URL: $WEBHOOK_DOMAIN$WEBHOOK_PATH
API Library: $API_LIBRARY
Server Port: $SERVER_PORT
Admin User ID: $ADMIN_USER_ID
PM2 Setup: $SETUP_PM2
SSL Setup: $SETUP_SSL
"
    
    read -p "Continue with these settings? (Y/n): " CONFIRM
    CONFIRM=${CONFIRM:-Y}
    if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
        error_exit "Setup cancelled by user"
    fi
}

# Update system packages
update_system() {
    info_msg "Updating system packages..."
    sudo apt update && sudo apt upgrade -y
    success_msg "System packages updated"
}

# Install Node.js
install_nodejs() {
    info_msg "Installing latest Node.js..."
    
    # Install NodeSource setup script
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
    
    # Verify installation
    NODE_VERSION=$(node --version)
    NPM_VERSION=$(npm --version)
    
    success_msg "Node.js installed: $NODE_VERSION"
    success_msg "npm installed: $NPM_VERSION"
}

# Install Nginx
install_nginx() {
    info_msg "Installing Nginx..."
    sudo apt install -y nginx
    sudo systemctl enable nginx
    sudo systemctl start nginx
    success_msg "Nginx installed and started"
}

# Install PM2
install_pm2() {
    if [[ $SETUP_PM2 =~ ^[Yy]$ ]]; then
        info_msg "Installing PM2..."
        sudo npm install -g pm2
        success_msg "PM2 installed globally"
    fi
}

# Install Certbot for SSL
install_certbot() {
    if [[ $SETUP_SSL =~ ^[Yy]$ ]]; then
        info_msg "Installing Certbot for SSL certificates..."
        sudo apt install -y certbot python3-certbot-nginx
        success_msg "Certbot installed"
    fi
}

# Create project directory and files
create_project() {
    info_msg "Creating project structure..."
    
    PROJECT_PATH="/home/$(whoami)/$PROJECT_NAME"
    mkdir -p "$PROJECT_PATH"
    cd "$PROJECT_PATH"
    
    # Initialize npm project
    npm init -y
    
    # Install dependencies based on API library choice
    case $API_LIBRARY in
        "node-telegram-bot-api")
            npm install node-telegram-bot-api express dotenv
            create_node_telegram_bot_api_files
            ;;
        "telegraf")
            npm install telegraf express dotenv
            create_telegraf_files
            ;;
        "grammy")
            npm install grammy @grammyjs/runner express dotenv
            create_grammy_files
            ;;
    esac
    
    # Install development dependencies
    npm install --save-dev nodemon
    
    # Create .env file
    create_env_file
    
    # Create PM2 ecosystem file
    if [[ $SETUP_PM2 =~ ^[Yy]$ ]]; then
        create_pm2_ecosystem
    fi
    
    success_msg "Project structure created at $PROJECT_PATH"
}

# Create .env file
create_env_file() {
    cat > .env << EOF
# Telegram Bot Configuration
BOT_TOKEN=$BOT_TOKEN
ADMIN_USER_ID=$ADMIN_USER_ID

# Server Configuration
PORT=$SERVER_PORT
WEBHOOK_DOMAIN=$WEBHOOK_DOMAIN
WEBHOOK_PATH=$WEBHOOK_PATH
WEBHOOK_URL=\${WEBHOOK_DOMAIN}\${WEBHOOK_PATH}

# Environment
NODE_ENV=production

# Optional: Database Configuration (uncomment and configure as needed)
# DATABASE_URL=mongodb://localhost:27017/telegram-bot
# REDIS_URL=redis://localhost:6379

# Optional: Logging
LOG_LEVEL=info
EOF

    success_msg ".env file created"
}

# Create Telegraf bot files
create_telegraf_files() {
    # Main bot file
    cat > bot.js << 'EOF'
const { Telegraf } = require('telegraf');
const express = require('express');
require('dotenv').config();

// Validate required environment variables
const requiredEnvVars = ['BOT_TOKEN', 'WEBHOOK_URL', 'PORT'];
const missingEnvVars = requiredEnvVars.filter(varName => !process.env[varName]);

if (missingEnvVars.length > 0) {
    console.error('Missing required environment variables:', missingEnvVars.join(', '));
    process.exit(1);
}

// Initialize bot
const bot = new Telegraf(process.env.BOT_TOKEN);

// Middleware for logging
bot.use((ctx, next) => {
    console.log(`[${new Date().toISOString()}] ${ctx.updateType} from ${ctx.from?.username || ctx.from?.id}`);
    return next();
});

// Command handlers
bot.start((ctx) => {
    const welcomeMessage = `
🤖 Welcome to the bot!

I'm up and running successfully!

Available commands:
/start - Show this welcome message
/help - Get help information
/ping - Check bot status
    `;
    
    ctx.reply(welcomeMessage);
    
    // Notify admin of new user
    if (process.env.ADMIN_USER_ID && ctx.from.id != process.env.ADMIN_USER_ID) {
        bot.telegram.sendMessage(
            process.env.ADMIN_USER_ID,
            `🔔 New user started the bot: ${ctx.from.first_name} (@${ctx.from.username || 'no username'}) - ID: ${ctx.from.id}`
        ).catch(console.error);
    }
});

bot.help((ctx) => {
    ctx.reply(`
🔧 Bot Help

This bot is running in production mode.
Contact the administrator for support.

Available commands:
/start - Welcome message
/help - This help message
/ping - Bot status check
    `);
});

bot.command('ping', (ctx) => {
    const uptime = process.uptime();
    const uptimeHours = Math.floor(uptime / 3600);
    const uptimeMinutes = Math.floor((uptime % 3600) / 60);
    
    ctx.reply(`
🏓 Pong!

Bot Status: ✅ Online
Uptime: ${uptimeHours}h ${uptimeMinutes}m
Server Time: ${new Date().toISOString()}
    `);
});

// Error handling
bot.catch((err, ctx) => {
    console.error('Bot error:', err);
    
    // Notify admin of errors
    if (process.env.ADMIN_USER_ID) {
        bot.telegram.sendMessage(
            process.env.ADMIN_USER_ID,
            `🚨 Bot Error: ${err.message}\nUser: ${ctx.from?.username || ctx.from?.id}`
        ).catch(console.error);
    }
});

// Express server for webhook
const app = express();
app.use(express.json());

// Health check endpoint
app.get('/health', (req, res) => {
    res.json({ 
        status: 'OK', 
        timestamp: new Date().toISOString(),
        uptime: process.uptime()
    });
});

// Webhook endpoint
app.post(process.env.WEBHOOK_PATH, (req, res) => {
    bot.handleUpdate(req.body);
    res.sendStatus(200);
});

// Start server
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
    console.log(`🚀 Server running on port ${PORT}`);
    console.log(`📡 Webhook URL: ${process.env.WEBHOOK_URL}`);
    
    // Set webhook
    bot.telegram.setWebhook(process.env.WEBHOOK_URL)
        .then(() => {
            console.log('✅ Webhook set successfully');
            
            // Send startup notification to admin
            if (process.env.ADMIN_USER_ID) {
                bot.telegram.sendMessage(
                    process.env.ADMIN_USER_ID,
                    `🚀 Bot started successfully!\n\nWebhook: ${process.env.WEBHOOK_URL}\nServer: Port ${PORT}\nTime: ${new Date().toISOString()}`
                ).catch(console.error);
            }
        })
        .catch(err => {
            console.error('❌ Failed to set webhook:', err);
        });
});

// Graceful shutdown
process.on('SIGINT', () => {
    console.log('🛑 Shutting down gracefully...');
    bot.telegram.deleteWebhook().then(() => {
        console.log('✅ Webhook deleted');
        process.exit(0);
    });
});

process.on('SIGTERM', () => {
    console.log('🛑 SIGTERM received...');
    bot.telegram.deleteWebhook().then(() => {
        console.log('✅ Webhook deleted');
        process.exit(0);
    });
});

module.exports = { bot, app };
EOF

    # Webhook setup utility
    cat > setup-webhook.js << 'EOF'
const { Telegraf } = require('telegraf');
require('dotenv').config();

const bot = new Telegraf(process.env.BOT_TOKEN);

async function setupWebhook() {
    try {
        console.log('🔄 Setting up webhook...');
        console.log('Webhook URL:', process.env.WEBHOOK_URL);
        
        await bot.telegram.setWebhook(process.env.WEBHOOK_URL);
        console.log('✅ Webhook set successfully!');
        
        // Get webhook info
        const webhookInfo = await bot.telegram.getWebhookInfo();
        console.log('📡 Webhook Info:', JSON.stringify(webhookInfo, null, 2));
        
        // Send test message to admin
        if (process.env.ADMIN_USER_ID) {
            await bot.telegram.sendMessage(
                process.env.ADMIN_USER_ID,
                `🔧 Webhook configured!\n\nURL: ${process.env.WEBHOOK_URL}\nTime: ${new Date().toISOString()}`
            );
            console.log('📨 Test message sent to admin');
        }
        
    } catch (error) {
        console.error('❌ Error setting webhook:', error);
    }
}

setupWebhook();
EOF

    # Development start script
    cat > dev.js << 'EOF'
const { Telegraf } = require('telegraf');
require('dotenv').config();

// Override for development - use polling instead of webhook
process.env.NODE_ENV = 'development';

const bot = new Telegraf(process.env.BOT_TOKEN);

// Import bot logic from main file (without webhook setup)
bot.start((ctx) => {
    ctx.reply('🤖 Bot running in development mode!\n\nCommands:\n/start - This message\n/ping - Status check');
});

bot.command('ping', (ctx) => {
    ctx.reply(`🏓 Pong! Development mode\nTime: ${new Date().toISOString()}`);
});

bot.catch(console.error);

console.log('🔄 Starting bot in development mode (polling)...');
bot.launch();

// Enable graceful stop
process.once('SIGINT', () => bot.stop('SIGINT'));
process.once('SIGTERM', () => bot.stop('SIGTERM'));
EOF

    success_msg "Telegraf bot files created"
}

# Create node-telegram-bot-api files
create_node_telegram_bot_api_files() {
    cat > bot.js << 'EOF'
const TelegramBot = require('node-telegram-bot-api');
const express = require('express');
require('dotenv').config();

// Validate environment variables
if (!process.env.BOT_TOKEN || !process.env.WEBHOOK_URL || !process.env.PORT) {
    console.error('Missing required environment variables');
    process.exit(1);
}

// Initialize bot
const bot = new TelegramBot(process.env.BOT_TOKEN);

// Command handlers
bot.onText(/\/start/, (msg) => {
    const chatId = msg.chat.id;
    const welcomeMessage = `
🤖 Welcome ${msg.from.first_name}!

Bot is running successfully!

Commands:
/start - Welcome message
/help - Help information
/ping - Bot status
    `;
    
    bot.sendMessage(chatId, welcomeMessage);
    
    // Notify admin
    if (process.env.ADMIN_USER_ID && msg.from.id != process.env.ADMIN_USER_ID) {
        bot.sendMessage(
            process.env.ADMIN_USER_ID,
            `🔔 New user: ${msg.from.first_name} (@${msg.from.username || 'no username'})`
        ).catch(console.error);
    }
});

bot.onText(/\/help/, (msg) => {
    bot.sendMessage(msg.chat.id, '🔧 Bot Help\n\nAvailable commands:\n/start\n/help\n/ping');
});

bot.onText(/\/ping/, (msg) => {
    const uptime = Math.floor(process.uptime() / 60);
    bot.sendMessage(msg.chat.id, `🏓 Pong!\n\nUptime: ${uptime} minutes\nTime: ${new Date().toISOString()}`);
});

// Express server
const app = express();
app.use(express.json());

app.get('/health', (req, res) => {
    res.json({ status: 'OK', timestamp: new Date().toISOString() });
});

app.post(process.env.WEBHOOK_PATH, (req, res) => {
    bot.processUpdate(req.body);
    res.sendStatus(200);
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
    console.log(`🚀 Server running on port ${PORT}`);
    
    // Set webhook
    bot.setWebHook(process.env.WEBHOOK_URL)
        .then(() => {
            console.log('✅ Webhook set successfully');
            if (process.env.ADMIN_USER_ID) {
                bot.sendMessage(
                    process.env.ADMIN_USER_ID,
                    `🚀 Bot started!\nWebhook: ${process.env.WEBHOOK_URL}`
                ).catch(console.error);
            }
        })
        .catch(console.error);
});

module.exports = { bot, app };
EOF

    cat > setup-webhook.js << 'EOF'
const TelegramBot = require('node-telegram-bot-api');
require('dotenv').config();

const bot = new TelegramBot(process.env.BOT_TOKEN);

async function setupWebhook() {
    try {
        console.log('🔄 Setting webhook...');
        await bot.setWebHook(process.env.WEBHOOK_URL);
        console.log('✅ Webhook set!');
        
        const info = await bot.getWebHookInfo();
        console.log('📡 Webhook info:', info);
    } catch (error) {
        console.error('❌ Error:', error);
    }
}

setupWebhook();
EOF

    success_msg "node-telegram-bot-api files created"
}

# Create Grammy files
create_grammy_files() {
    cat > bot.js << 'EOF'
const { Bot } = require('grammy');
const { run } = require('@grammyjs/runner');
const express = require('express');
require('dotenv').config();

// Initialize bot
const bot = new Bot(process.env.BOT_TOKEN);

// Middleware
bot.use((ctx, next) => {
    console.log(`[${new Date().toISOString()}] Update from ${ctx.from?.username || ctx.from?.id}`);
    return next();
});

// Commands
bot.command('start', (ctx) => {
    ctx.reply(`🤖 Welcome ${ctx.from.first_name}!\n\nBot powered by Grammy framework!\n\nCommands:\n/start\n/help\n/ping`);
    
    // Admin notification
    if (process.env.ADMIN_USER_ID && ctx.from.id != process.env.ADMIN_USER_ID) {
        bot.api.sendMessage(
            process.env.ADMIN_USER_ID,
            `🔔 New user: ${ctx.from.first_name} (@${ctx.from.username || 'no username'})`
        ).catch(console.error);
    }
});

bot.command('help', (ctx) => {
    ctx.reply('🔧 Grammy Bot Help\n\nCommands:\n/start - Welcome\n/help - This message\n/ping - Status');
});

bot.command('ping', (ctx) => {
    const uptime = Math.floor(process.uptime() / 60);
    ctx.reply(`🏓 Pong!\n\nUptime: ${uptime}m\nTime: ${new Date().toISOString()}`);
});

// Error handling
bot.errorBoundary((err) => {
    console.error('Bot error:', err);
});

// Express server
const app = express();
app.use(express.json());

app.get('/health', (req, res) => {
    res.json({ status: 'OK', framework: 'Grammy' });
});

app.post(process.env.WEBHOOK_PATH, (req, res) => {
    bot.handleUpdate(req.body);
    res.sendStatus(200);
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, async () => {
    console.log(`🚀 Grammy bot server on port ${PORT}`);
    
    try {
        await bot.api.setWebhook(process.env.WEBHOOK_URL);
        console.log('✅ Webhook set');
        
        if (process.env.ADMIN_USER_ID) {
            await bot.api.sendMessage(
                process.env.ADMIN_USER_ID,
                `🚀 Grammy bot started!\nWebhook: ${process.env.WEBHOOK_URL}`
            );
        }
    } catch (error) {
        console.error('❌ Webhook error:', error);
    }
});

module.exports = { bot, app };
EOF

    success_msg "Grammy bot files created"
}

# Create PM2 ecosystem file
create_pm2_ecosystem() {
    cat > ecosystem.config.js << EOF
module.exports = {
  apps: [{
    name: '$PROJECT_NAME',
    script: 'bot.js',
    instances: 1,
    autorestart: true,
    watch: true,
    ignore_watch: [
      'node_modules',
      'logs',
      '.git',
      '.env'
    ],
    max_memory_restart: '1G',
    env: {
      NODE_ENV: 'production',
      PORT: $SERVER_PORT
    },
    env_development: {
      NODE_ENV: 'development',
      PORT: $SERVER_PORT
    },
    log_file: './logs/combined.log',
    out_file: './logs/out.log',
    error_file: './logs/error.log',
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z'
  }]
};
EOF

    # Create logs directory
    mkdir -p logs
    
    success_msg "PM2 ecosystem configuration created"
}

# Configure Nginx
configure_nginx() {
    info_msg "Configuring Nginx..."
    
    # Backup default config
    sudo cp /etc/nginx/sites-available/default /etc/nginx/sites-available/default.backup
    
    # Create new site configuration
    sudo tee /etc/nginx/sites-available/$PROJECT_NAME << EOF
server {
    listen 80;
    server_name $DOMAIN;
    
    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    
    # Rate limiting
    limit_req_zone \$binary_remote_addr zone=webhook:10m rate=10r/s;
    
    location $WEBHOOK_PATH {
        limit_req zone=webhook burst=20 nodelay;
        
        proxy_pass http://127.0.0.1:$SERVER_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        
        # Timeout settings
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    location /health {
        proxy_pass http://127.0.0.1:$SERVER_PORT;
        proxy_set_header Host \$host;
    }
    
    # Block direct access to other paths
    location / {
        return 404;
    }
}
EOF

    # Enable the site
    sudo ln -sf /etc/nginx/sites-available/$PROJECT_NAME /etc/nginx/sites-enabled/
    
    # Remove default site if it exists
    sudo rm -f /etc/nginx/sites-enabled/default
    
    # Test nginx configuration
    if sudo nginx -t; then
        sudo systemctl reload nginx
        success_msg "Nginx configuration updated successfully"
    else
        error_exit "Nginx configuration test failed"
    fi
}

# Setup SSL certificate
setup_ssl() {
    if [[ $SETUP_SSL =~ ^[Yy]$ ]]; then
        info_msg "Setting up SSL certificate with Let's Encrypt..."
        
        # Get certificate
        sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN --redirect
        
        if [[ $? -eq 0 ]]; then
            success_msg "SSL certificate installed successfully"
            
            # Setup auto-renewal
            sudo systemctl enable certbot.timer
            sudo systemctl start certbot.timer
            
            success_msg "SSL auto-renewal configured"
        else
            warn_msg "SSL certificate installation failed. You can run it manually later with: sudo certbot --nginx -d $DOMAIN"
        fi
    fi
}

# Setup PM2
setup_pm2() {
    if [[ $SETUP_PM2 =~ ^[Yy]$ ]]; then
        info_msg "Setting up PM2 process management..."
        
        # Start the bot with PM2
        pm2 start ecosystem.config.js --env production
        
        # Save PM2 process list
        pm2 save
        
        # Setup PM2 startup script
        pm2 startup systemd -u $(whoami) --hp /home/$(whoami) | grep -E '^sudo' | bash
        
        success_msg "PM2 setup completed"
        
        # Show PM2 status
        pm2 status
    fi
}

# Update package.json scripts
update_package_scripts() {
    info_msg "Updating package.json scripts..."
    
    # Read current package.json
    local package_json=$(cat package.json)
    
    # Create new scripts section
    local new_scripts='"scripts": {
    "start": "node bot.js",
    "dev": "node dev.js",
    "setup-webhook": "node setup-webhook.js",
    "pm2:start": "pm2 start ecosystem.config.js --env production",
    "pm2:stop": "pm2 stop ecosystem.config.js",
    "pm2:restart": "pm2 restart ecosystem.config.js",
    "pm2:delete": "pm2 delete ecosystem.config.js",
    "pm2:logs": "pm2 logs",
    "pm2:monit": "pm2 monit",
    "logs": "tail -f logs/combined.log",
    "health": "curl http://localhost:'$SERVER_PORT'/health"
  },'
    
    # Replace scripts section
    echo "$package_json" | sed 's/"scripts": {[^}]*},/'"$new_scripts"'/' > package.json
    
    success_msg "Package.json scripts updated"
}

# Create documentation
create_documentation() {
    info_msg "Creating project documentation..."
    
    cat > README.md << EOF
# $PROJECT_NAME

Telegram bot created with automated setup script.

## 🚀 Quick Start

### Development Mode
\`\`\`bash
npm run dev
\`\`\`

### Production Mode
\`\`\`bash
npm start
\`\`\`

### PM2 Process Management
\`\`\`bash
# Start with PM2
npm run pm2:start

# View logs
npm run pm2:logs

# Monitor processes
npm run pm2:monit

# Restart bot
npm run pm2:restart

# Stop bot
npm run pm2:stop
\`\`\`

## 📡 Webhook Management

### Setup Webhook
\`\`\`bash
npm run setup-webhook
\`\`\`

### Check Bot Health
\`\`\`bash
npm run health
# Or visit: $WEBHOOK_DOMAIN/health
\`\`\`

## 🔧 Configuration

Environment variables are stored in \`.env\`:

- \`BOT_TOKEN\`: Your Telegram bot token
- \`WEBHOOK_DOMAIN\`: Your domain (e.g., https://example.com)
- \`WEBHOOK_PATH\`: Webhook endpoint path
- \`PORT\`: Server port
- \`ADMIN_USER_ID\`: Telegram user ID for admin notifications

## 📁 Project Structure

\`\`\`
$PROJECT_NAME/
├── bot.js                 # Main bot application
├── setup-webhook.js       # Webhook configuration utility
├── dev.js                # Development mode script
├── ecosystem.config.js    # PM2 configuration
├── package.json          # Node.js dependencies
├── .env                  # Environment variables
├── logs/                 # Application logs
│   ├── combined.log
│   ├── error.log
│   └── out.log
└── README.md            # This file
\`\`\`

## 🔒 Security Features

- Rate limiting on webhook endpoint
- Security headers configured in Nginx
- SSL certificate with Let's Encrypt
- Input validation and error handling
- Admin-only notifications

## 📊 Monitoring

### View Logs
\`\`\`bash
# Real-time logs
npm run logs

# PM2 logs
npm run pm2:logs

# System logs
sudo journalctl -u nginx -f
\`\`\`

### Health Checks
- Bot health: \`$WEBHOOK_DOMAIN/health\`
- Nginx status: \`sudo systemctl status nginx\`
- PM2 status: \`pm2 status\`

## 🛠 Maintenance

### Update Bot Code
1. Edit \`bot.js\` with your changes
2. If using PM2 with watch mode, changes will auto-reload
3. Manual restart: \`npm run pm2:restart\`

### SSL Certificate Renewal
Certificates auto-renew via systemd timer. Manual renewal:
\`\`\`bash
sudo certbot renew --dry-run
\`\`\`

### Nginx Configuration
Config file: \`/etc/nginx/sites-available/$PROJECT_NAME\`

After changes:
\`\`\`bash
sudo nginx -t
sudo systemctl reload nginx
\`\`\`

## 🐛 Troubleshooting

### Bot Not Responding
1. Check if process is running: \`pm2 status\`
2. Check logs: \`npm run pm2:logs\`
3. Verify webhook: \`npm run setup-webhook\`
4. Test health endpoint: \`npm run health\`

### SSL Issues
1. Check certificate status: \`sudo certbot certificates\`
2. Verify domain DNS points to server
3. Check Nginx config: \`sudo nginx -t\`

### Common Commands
\`\`\`bash
# Restart all services
sudo systemctl restart nginx
npm run pm2:restart

# Check all logs
npm run pm2:logs
sudo journalctl -u nginx -n 50

# Reset webhook
npm run setup-webhook
\`\`\`

## 📞 Support

Bot created: $(date)
Domain: $DOMAIN
API Library: $API_LIBRARY
Admin ID: $ADMIN_USER_ID

For issues, check the logs first, then verify:
1. Environment variables in \`.env\`
2. Nginx configuration
3. SSL certificate status
4. PM2 process status
EOF

    # Create .gitignore
    cat > .gitignore << EOF
# Dependencies
node_modules/
npm-debug.log*
yarn-debug.log*
yarn-error.log*

# Environment variables
.env
.env.local
.env.development.local
.env.test.local
.env.production.local

# Logs
logs/
*.log

# Runtime data
pids/
*.pid
*.seed
*.pid.lock

# PM2
.pm2/

# IDE
.vscode/
.idea/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db

# Temporary files
tmp/
temp/
EOF

    success_msg "Documentation created"
}

# Set proper file permissions
set_permissions() {
    info_msg "Setting file permissions..."
    
    # Set ownership
    chown -R $(whoami):$(whoami) "$PROJECT_PATH"
    
    # Set permissions
    chmod 755 "$PROJECT_PATH"
    chmod 644 "$PROJECT_PATH"/*.js
    chmod 644 "$PROJECT_PATH"/.env
    chmod 755 "$PROJECT_PATH"/logs
    
    # Make scripts executable
    chmod +x "$PROJECT_PATH"/setup-webhook.js
    
    success_msg "File permissions set"
}

# Generate setup summary
generate_summary() {
    SETUP_SUMMARY="
╔═══════════════════════════════════════════════════════════════╗
║                    SETUP COMPLETED SUCCESSFULLY!             ║
╚═══════════════════════════════════════════════════════════════╝

🎉 Your Telegram bot is ready!

📋 PROJECT DETAILS:
   • Name: $PROJECT_NAME
   • Path: $PROJECT_PATH
   • Domain: $DOMAIN
   • Webhook: $WEBHOOK_DOMAIN$WEBHOOK_PATH
   • API Library: $API_LIBRARY
   • Server Port: $SERVER_PORT

🔧 SERVICES STATUS:
   • Nginx: $(systemctl is-active nginx)
   • SSL: $(if [[ $SETUP_SSL =~ ^[Yy]$ ]]; then echo "Enabled"; else echo "Disabled"; fi)
   • PM2: $(if [[ $SETUP_PM2 =~ ^[Yy]$ ]]; then echo "Configured"; else echo "Not configured"; fi)

🚀 NEXT STEPS:
   1. Test your bot by sending /start in Telegram
   2. Check health: curl $WEBHOOK_DOMAIN/health
   3. Monitor logs: cd $PROJECT_PATH && npm run logs
   4. View PM2 status: pm2 status

📚 USEFUL COMMANDS:
   • Start development: npm run dev
   • Setup webhook: npm run setup-webhook
   • View logs: npm run pm2:logs
   • Restart bot: npm run pm2:restart

📁 PROJECT STRUCTURE:
   $PROJECT_PATH/
   ├── bot.js (main application)
   ├── setup-webhook.js (webhook utility)
   ├── ecosystem.config.js (PM2 config)
   ├── .env (environment variables)
   └── README.md (documentation)

🔐 SECURITY:
   • Rate limiting enabled
   • SSL certificate installed
   • Security headers configured
   • Admin notifications active

💡 TIPS:
   • Bot automatically restarts on code changes (PM2 watch mode)
   • SSL certificates auto-renew via systemd timer
   • Check README.md for detailed documentation
   • Admin notifications sent to Telegram ID: $ADMIN_USER_ID

🌐 ACCESS:
   • Bot webhook: $WEBHOOK_DOMAIN$WEBHOOK_PATH
   • Health check: $WEBHOOK_DOMAIN/health
   • Project folder: $PROJECT_PATH

Happy botting! 🤖
"
}

# Main execution function
main() {
    print_banner
    
    # Pre-flight checks
    check_root
    check_system
    
    # Collect configuration
    collect_inputs
    
    # System setup
    info_msg "Starting system setup..."
    update_system
    install_nodejs
    install_nginx
    install_pm2
    install_certbot
    
    # Project creation
    info_msg "Creating project..."
    create_project
    update_package_scripts
    create_documentation
    set_permissions
    
    # Server configuration
    info_msg "Configuring server..."
    configure_nginx
    setup_ssl
    
    # Process management
    setup_pm2
    
    # Final steps
    generate_summary
    
    # Display summary
    print_colored "$GREEN" "$SETUP_SUMMARY"
    
    # Save summary to file
    echo "$SETUP_SUMMARY" > "$PROJECT_PATH/SETUP_SUMMARY.txt"
    
    # Final instructions
    print_colored "$CYAN" "
╔═══════════════════════════════════════════════════════════════╗
║  Setup complete! Check SETUP_SUMMARY.txt for full details.   ║
║                                                               ║
║  Your bot should now be accessible at:                       ║
║  $WEBHOOK_DOMAIN$WEBHOOK_PATH                            ║
║                                                               ║
║  Test it by messaging your bot on Telegram!                  ║
╚═══════════════════════════════════════════════════════════════╝
"
    
    success_msg "Telegram bot setup completed successfully!"
    log "Setup completed for project: $PROJECT_NAME"
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
