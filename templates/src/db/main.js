import mariadb from 'mariadb';
import * as dotenv from 'dotenv';
dotenv.config();

export const pool = mariadb.createPool({
  host: process.env.DB_HOST || 'localhost',
  port: process.env.DB_PORT || 3306,
  user: process.env.DB_USER,
  password: process.env.DB_PASS,
  database: process.env.DB_NAME,
  charset: 'utf8mb4',
  connectionLimit: parseInt(process.env.DB_POOL_LIMIT) || 30,
  waitForConnections: true,
  queueLimit: 0,
  connectTimeout: 20000,
  multipleStatements: false
});