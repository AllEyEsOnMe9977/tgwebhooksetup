import { pool } from './main.js';

export class UserManager {
  // Returns true if this is a new user just inserted
  static async upsertUser(user) {
    let conn;
    try {
      conn = await pool.getConnection();
      // Try insert, ignore if already exists, update info
      const res = await conn.query(`
        INSERT INTO users (user_id, username, first_name, last_name, is_bot, language_code)
        VALUES (?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
          username=VALUES(username),
          first_name=VALUES(first_name),
          last_name=VALUES(last_name),
          is_bot=VALUES(is_bot),
          language_code=VALUES(language_code)
      `, [
        user.id,
        user.username || null,
        user.first_name || null,
        user.last_name || null,
        user.is_bot ? 1 : 0,
        user.language_code || null
      ]);
      // If insertId is set and not 0, this was a new user
      return res.insertId && res.insertId !== 0;
    } finally {
      if (conn) conn.release();
    }
  }

  // Get a user's join info
  static async getUser(user_id) {
    let conn;
    try {
      conn = await pool.getConnection();
      const rows = await conn.query(
        `SELECT * FROM users WHERE user_id = ? LIMIT 1`,
        [user_id]
      );
      return rows.length ? rows[0] : null;
    } finally {
      if (conn) conn.release();
    }
  }
  static async setUserLang(user_id, lang) {
    let conn;
    try {
        conn = await pool.getConnection();
        await conn.query(
        `UPDATE users SET selected_lang = ? WHERE user_id = ?`,
        [lang, Number(user_id)]
        );
    } finally {
        if (conn) conn.release();
    }
  }
}