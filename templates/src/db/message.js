import { pool } from './main.js';

export async function saveMessage(chatId, userId, username, text) {
  let conn;
  try {
    conn = await pool.getConnection();
    await conn.query(
      `INSERT INTO messages (chat_id, user_id, username, text) VALUES (?, ?, ?, ?)`,
      [chatId, userId, username, text]
    );
  } finally {
    if (conn) conn.release();
  }
}

export async function getLastMessages(n = 5) {
  let conn;
  try {
    conn = await pool.getConnection();
    const rows = await conn.query(
      `SELECT * FROM messages ORDER BY id DESC LIMIT ?`, [n]
    );
    return rows.reverse(); // oldest first
  } finally {
    if (conn) conn.release();
  }
}
