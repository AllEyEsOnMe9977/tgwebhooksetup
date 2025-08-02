import { pool } from './main.js';

// Replacer function: safely converts BigInt to Number
function jsonReplacer(key, value) {
  return typeof value === 'bigint' ? Number(value) : value;
}

export class UserStateManager {
  static async setState(user_id, chat_id, menu_state, data = {}, last_message_id = null) {
    let conn;
    try {
      // Always use JSON.stringify with BigInt-safe replacer
      const dataJson = (() => {
        try {
          if (typeof data === "string") {
            JSON.parse(data);
            return data;
          }
        } catch {}
        return JSON.stringify(data ?? {}, jsonReplacer);
      })();

      conn = await pool.getConnection();
      await conn.query(`
        INSERT INTO user_states (user_id, chat_id, menu_state, data, last_message_id)
        VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
          menu_state = VALUES(menu_state),
          data = VALUES(data),
          last_message_id = VALUES(last_message_id),
          updated_at = CURRENT_TIMESTAMP
      `, [
        Number(user_id),
        Number(chat_id),
        menu_state,
        dataJson,
        last_message_id !== null ? Number(last_message_id) : null
      ]);
    } finally {
      if (conn) conn.release();
    }
  }

  static async getState(user_id, chat_id) {
    let conn;
    try {
      conn = await pool.getConnection();
      const rows = await conn.query(
        `SELECT * FROM user_states WHERE user_id = ? AND chat_id = ? LIMIT 1`,
        [Number(user_id), Number(chat_id)]
      );
      if (rows.length) {
        const state = rows[0];
        try {
          state.data = state.data && typeof state.data === "string"
            ? JSON.parse(state.data)
            : {};
        } catch {
          state.data = {};
        }
        return state;
      }
      return null;
    } finally {
      if (conn) conn.release();
    }
  }

  static async deleteState(user_id, chat_id) {
    let conn;
    try {
      conn = await pool.getConnection();
      await conn.query(
        `DELETE FROM user_states WHERE user_id = ? AND chat_id = ?`,
        [Number(user_id), Number(chat_id)]
      );
    } finally {
      if (conn) conn.release();
    }
  }

  static async usersInState(menu_state) {
    let conn;
    try {
      conn = await pool.getConnection();
      const rows = await conn.query(
        `SELECT * FROM user_states WHERE menu_state = ?`,
        [menu_state]
      );
      return rows.map(row => {
        let data;
        try {
          data = row.data && typeof row.data === "string"
            ? JSON.parse(row.data)
            : {};
        } catch {
          data = {};
        }
        return {
          user_id: Number(row.user_id),
          chat_id: Number(row.chat_id),
          last_message_id: row.last_message_id !== null ? Number(row.last_message_id) : null,
          data,
          updated_at: row.updated_at
        };
      });
    } finally {
      if (conn) conn.release();
    }
  }
}
