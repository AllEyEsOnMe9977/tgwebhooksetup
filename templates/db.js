//db.js
import mariadb from 'mariadb';
import * as dotenv from 'dotenv';
dotenv.config();

const pool = mariadb.createPool({
  host: process.env.DB_HOST || 'localhost',
  user: process.env.DB_USER,
  password: process.env.DB_PASS,
  database: process.env.DB_NAME,
  connectionLimit: 5
});

export async function testDb() {
  let conn;
  try {
    conn = await pool.getConnection();
    await conn.query(`
      CREATE TABLE IF NOT EXISTS test_table (
        id INT AUTO_INCREMENT PRIMARY KEY,
        value VARCHAR(255) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);
    await conn.query("INSERT INTO test_table(value) VALUES (?)", ['Sample Data']);
    const rows = await conn.query("SELECT * FROM test_table ORDER BY id DESC LIMIT 1");
    return rows[0];
  } catch (err) {
    console.error("MariaDB error:", err);
    throw err;
  } finally {
    if (conn) conn.release();
  }
}
