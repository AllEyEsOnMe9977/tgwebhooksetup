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

export async function getLastMessage() {
  let conn;
  try {
    conn = await pool.getConnection();
    const rows = await conn.query(
      `SELECT * FROM messages ORDER BY id DESC LIMIT 1`
    );
    return rows[0] || null;
  } finally {
    if (conn) conn.release();
  }
}
