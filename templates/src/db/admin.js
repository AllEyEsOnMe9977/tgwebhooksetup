// db/admin.js
import { pool } from './main.js';

// Utility: Run a DB query and return results (array of rows)
export async function adminQuery(sql, params = []) {
  let conn;
  try {
    conn = await pool.getConnection();
    const rows = await conn.query(sql, params);
    return rows;
  } finally {
    if (conn) conn.release();
  }
}

// Show admin dashboard/help
export function getAdminHelp() {
  return [
    '🛠 <b>Admin Commands</b>:',
    '/cmds - List all commands and usage count',
    '/interactions N - Last N interactions (default 10)',
    '/active - Top 5 active users',
    '/buttons - Top 5 clicked buttons',
    '/cmdstat - Show most-used commands',
    '/msgs N - Last N user messages',
    '/clearinteractions - Delete ALL interactions (Danger!)',
    '/adminhelp - Show this help'
  ].join('\n');
}

// Get all commands with usage count
export async function getCommandsStats(limit = 20) {
  const sql = `
    SELECT payload AS command, COUNT(*) AS uses
    FROM interactions
    WHERE type = 'command'
    GROUP BY payload
    ORDER BY uses DESC
    LIMIT ?
  `;
  return await adminQuery(sql, [limit]);
}

// Get last N interactions (all types)
export async function getLastInteractions(n = 10) {
  const sql = `
    SELECT * FROM interactions
    ORDER BY created_at DESC
    LIMIT ?
  `;
  return await adminQuery(sql, [n]);
}

// Top N active users
export async function getActiveUsers(limit = 5) {
  const sql = `
    SELECT user_id, COUNT(*) AS total
    FROM interactions
    GROUP BY user_id
    ORDER BY total DESC
    LIMIT ?
  `;
  return await adminQuery(sql, [limit]);
}

// Top N clicked buttons
export async function getTopButtons(limit = 5) {
  const sql = `
    SELECT payload AS button, COUNT(*) AS clicks
    FROM interactions
    WHERE type = 'callback'
    GROUP BY button
    ORDER BY clicks DESC
    LIMIT ?
  `;
  return await adminQuery(sql, [limit]);
}

// Show most-used commands
export async function getMostUsedCommands(limit = 10) {
  const sql = `
    SELECT payload AS command, COUNT(*) AS count
    FROM interactions
    WHERE type = 'command'
    GROUP BY command
    ORDER BY count DESC
    LIMIT ?
  `;
  return await adminQuery(sql, [limit]);
}

// Last N user messages (text only)
export async function getLastUserMessages(n = 10) {
  const sql = `
    SELECT * FROM interactions
    WHERE type = 'text'
    ORDER BY created_at DESC
    LIMIT ?
  `;
  return await adminQuery(sql, [n]);
}

// Danger: Clear all interactions
export async function clearInteractions() {
  const sql = `TRUNCATE TABLE interactions`;
  await adminQuery(sql);
}
