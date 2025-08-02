import { pool } from './main.js';

export async function trackInteraction({
  user_id,
  chat_id,
  type,
  payload = null,
  message_id = null
}) {
  let conn;
  try {
    conn = await pool.getConnection();
    await conn.query(
      `INSERT INTO interactions (user_id, chat_id, type, payload, message_id)
       VALUES (?, ?, ?, ?, ?)`,
      [
        Number(user_id),
        Number(chat_id),
        type,
        payload,
        message_id !== null ? Number(message_id) : null
      ]
    );
  } finally {
    if (conn) conn.release();
  }
}
