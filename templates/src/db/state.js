import { pool } from './main.js';

export class UserStateManager {
  // Save or update a user's menu state (plus arbitrary data and message id)
  static async setState(user_id, chat_id, menu_state, data = {}, last_message_id = null) {
    let conn;
    try {
      conn = await pool.getConnection();
      await conn.query(`
        INSERT INTO user_states (user_id, chat_id, menu_state, data, last_message_id)
        VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
          menu_state = VALUES(menu_state),
          data = VALUES(data),
          last_message_id = VALUES(last_message_id),
          updated_at = CURRENT_TIMESTAMP
      `, [user_id, chat_id, menu_state, JSON.stringify(data), last_message_id]);
    } finally {
      if (conn) conn.release();
    }
  }

  // Fetch user state (returns null if not present)
  static async getState(user_id, chat_id) {
    let conn;
    try {
      conn = await pool.getConnection();
      const rows = await conn.query(
        `SELECT * FROM user_states WHERE user_id = ? AND chat_id = ? LIMIT 1`,
        [user_id, chat_id]
      );
      if (rows.length) {
        const state = rows[0];
        state.data = state.data ? JSON.parse(state.data) : {};
        return state;
      }
      return null;
    } finally {
      if (conn) conn.release();
    }
  }

  // Delete user state (if user logs out, etc)
  static async deleteState(user_id, chat_id) {
    let conn;
    try {
      conn = await pool.getConnection();
      await conn.query(
        `DELETE FROM user_states WHERE user_id = ? AND chat_id = ?`,
        [user_id, chat_id]
      );
    } finally {
      if (conn) conn.release();
    }
  }

  // List all users in a menu state (for admin/batch ops)
  static async usersInState(menu_state) {
    let conn;
    try {
      conn = await pool.getConnection();
      const rows = await conn.query(
        `SELECT * FROM user_states WHERE menu_state = ?`,
        [menu_state]
      );
      return rows.map(row => ({
        user_id: row.user_id,
        chat_id: row.chat_id,
        last_message_id: row.last_message_id,
        data: row.data ? JSON.parse(row.data) : {},
        updated_at: row.updated_at
      }));
    } finally {
      if (conn) conn.release();
    }
  }
}
