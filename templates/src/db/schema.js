import { pool } from './main.js';

export async function ensureTables() {
  let conn;
  try {
    conn = await pool.getConnection();
    await conn.beginTransaction();

    await conn.query(`
      CREATE TABLE IF NOT EXISTS messages (
        id INT AUTO_INCREMENT PRIMARY KEY,
        chat_id BIGINT NOT NULL,
        user_id BIGINT NOT NULL,
        username VARCHAR(64),
        text TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_messages_chatid (chat_id),
        INDEX idx_messages_userid (user_id),
        INDEX idx_messages_createdat (created_at)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    `);

    await conn.query(`
      CREATE TABLE IF NOT EXISTS user_states (
        id INT AUTO_INCREMENT PRIMARY KEY,
        user_id BIGINT NOT NULL,
        chat_id BIGINT NOT NULL,
        menu_state VARCHAR(128),
        data JSON DEFAULT NULL,
        last_message_id BIGINT DEFAULT NULL,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        UNIQUE KEY uq_user_chat (user_id, chat_id),
        INDEX idx_userstates_userid (user_id),
        INDEX idx_userstates_chatid (chat_id),
        INDEX idx_userstates_lastmsg (last_message_id)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    `);

    await conn.query(`
      CREATE TABLE IF NOT EXISTS users (
        id INT AUTO_INCREMENT PRIMARY KEY,
        user_id BIGINT NOT NULL UNIQUE,
        username VARCHAR(64),
        first_name VARCHAR(64),
        last_name VARCHAR(64),
        is_bot BOOLEAN DEFAULT FALSE,
        language_code VARCHAR(16),
        selected_lang VARCHAR(8) DEFAULT NULL,
        joined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_users_username (username),
        INDEX idx_users_lang (language_code),
        INDEX idx_users_sel_lang (selected_lang)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    `);
    await conn.query(`
      CREATE TABLE IF NOT EXISTS interactions (
        id INT AUTO_INCREMENT PRIMARY KEY,
        user_id BIGINT NOT NULL,
        chat_id BIGINT NOT NULL,
        type VARCHAR(32) NOT NULL,
        payload TEXT,
        message_id BIGINT DEFAULT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_user_chat (user_id, chat_id),
        INDEX idx_type (type),
        INDEX idx_created_at (created_at)
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    `);

    await conn.commit();
  } catch (err) {
    if (conn) await conn.rollback();
    throw err;
  } finally {
    if (conn) conn.release();
  }
}