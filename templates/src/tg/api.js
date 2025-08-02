import fetch from 'node-fetch';
import fs from 'fs';

export class TelegramAPI {
  /**
   * @param {string} botToken — your bot’s token
   * @param {{ logger?: Console }} [options]
   */
  constructor(botToken, { logger = console } = {}) {
    if (!botToken) throw new Error('Bot token is required');
    this.API_URL = `https://api.telegram.org/bot${botToken}`;
    this.logger = logger;
  }

  /**
   * Generic GET/POST wrapper with retries, rate-limit handling, and logging.
   * @private
   * @param {string} method
   * @param {object} data
   * @param {boolean} isPost
   */
  async _call(method, data = {}, isPost = true) {
    const url = `${this.API_URL}/${method}`;
    const maxNetworkRetries = 3;
    let networkAttempts = 0;

    // Build fetch options
    const options = isPost
      ? {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(data),
        }
      : { method: 'GET' };
    const requestUrl = isPost
      ? url
      : `${url}?${new URLSearchParams(data)}`;

    while (true) {
      try {
        this.logger.info(`→ [${method}] Request`, { url: requestUrl, payload: data });
        const res = await fetch(requestUrl, options);
        const text = await res.text().catch(() => null);
        let json;
        try {
          json = text ? JSON.parse(text) : {};
        } catch (e) {
          throw new Error(`Invalid JSON response (${res.status}): ${text}`);
        }

        // HTTP-level errors
        if (!res.ok) {
          // Rate limited?
          if (res.status === 429) {
            // Bot API may return JSON.parameters.retry_after (sec) or a Retry-After header
            const retryAfter =
              json.parameters?.retry_after ||
              parseInt(res.headers.get('retry-after'), 10) ||
              1;
            this.logger.warn(`← [${method}] Rate limited. Retrying in ${retryAfter}s`, {
              status: res.status,
              error: json,
            });
            await new Promise(r => setTimeout(r, retryAfter * 1_000));
            continue;
          }
          // Other HTTP errors
          const msg = `HTTP ${res.status} ${res.statusText}`;
          this.logger.error(`← [${method}] HTTP error`, { status: res.status, body: json || text });
          throw new Error(msg);
        }

        // Bot API-level errors: always include ok, error_code, description (§ Making requests) :contentReference[oaicite:0]{index=0}
        if (json.ok === false) {
          const code = json.error_code;
          const desc = json.description;
          // Flood wait error (parameters.retry_after) :contentReference[oaicite:1]{index=1}
          if (json.parameters?.retry_after) {
            const wait = json.parameters.retry_after;
            this.logger.warn(`← [${method}] Flood wait ${wait}s`, { error_code: code, description: desc });
            await new Promise(r => setTimeout(r, wait * 1_000));
            continue;
          }
          this.logger.error(`← [${method}] Telegram API error ${code}`, { description: desc, data });
          throw new Error(`Telegram API Error ${code}: ${desc}`);
        }

        this.logger.info(`← [${method}] Success`, { result: json.result });
        return json.result;
      } catch (err) {
        // Network or parsing failures
        const isNetworkError =
          err.type === 'system' ||
          /ECONNRESET|ENOTFOUND|ETIMEDOUT/.test(err.message);
        if (isNetworkError && networkAttempts < maxNetworkRetries) {
          const backoff = 2 ** networkAttempts * 1_000;
          networkAttempts++;
          this.logger.warn(`*** Network error on [${method}]: ${err.message}. Retrying #${networkAttempts} in ${backoff}ms`);
          await new Promise(r => setTimeout(r, backoff));
          continue;
        }
        this.logger.error(`*** Failed [${method}]`, err);
        throw err;
      }
    }
  }

  // ===== Messaging =====
  sendMessage(chat_id, text, options = {}) {
    return this._call('sendMessage', { chat_id, text, ...options });
  }

  forwardMessage(chat_id, from_chat_id, message_id, options = {}) {
    return this._call('forwardMessage', { chat_id, from_chat_id, message_id, ...options });
  }

  sendPhoto(chat_id, photo, options = {}) {
    return this._call('sendPhoto', { chat_id, photo, ...options });
  }

  sendDocument(chat_id, document, options = {}) {
    return this._call('sendDocument', { chat_id, document, ...options });
  }

  sendAudio(chat_id, audio, options = {}) {
    return this._call('sendAudio', { chat_id, audio, ...options });
  }

  sendVideo(chat_id, video, options = {}) {
    return this._call('sendVideo', { chat_id, video, ...options });
  }

  sendMediaGroup(chat_id, media, options = {}) {
    return this._call('sendMediaGroup', { chat_id, media, ...options });
  }

  sendLocation(chat_id, latitude, longitude, options = {}) {
    return this._call('sendLocation', { chat_id, latitude, longitude, ...options });
  }

  sendContact(chat_id, phone_number, first_name, options = {}) {
    return this._call('sendContact', { chat_id, phone_number, first_name, ...options });
  }

  sendSticker(chat_id, sticker, options = {}) {
    return this._call('sendSticker', { chat_id, sticker, ...options });
  }

  editMessageText(chat_id, message_id, text, options = {}) {
    return this._call('editMessageText', { chat_id, message_id, text, ...options });
  }

  deleteMessage(chat_id, message_id) {
    return this._call('deleteMessage', { chat_id, message_id });
  }

  // ===== Keyboard & UI =====
  answerCallbackQuery(callback_query_id, options = {}) {
    return this._call('answerCallbackQuery', { callback_query_id, ...options });
  }

  sendChatAction(chat_id, action) {
    return this._call('sendChatAction', { chat_id, action });
  }

  // ===== User & Chat Info =====
  getMe() {
    return this._call('getMe', {}, false);
  }

  getUserProfilePhotos(user_id, options = {}) {
    return this._call('getUserProfilePhotos', { user_id, ...options }, false);
  }

  getChat(chat_id) {
    return this._call('getChat', { chat_id }, false);
  }

  getChatAdministrators(chat_id) {
    return this._call('getChatAdministrators', { chat_id }, false);
  }

  getChatMember(chat_id, user_id) {
    return this._call('getChatMember', { chat_id, user_id }, false);
  }

  getChatMembersCount(chat_id) {
    return this._call('getChatMemberCount', { chat_id }, false);
  }

  // ===== Updates (Polling) =====
  getUpdates(options = {}) {
    return this._call('getUpdates', options, false);
  }

  setWebhook(url, options = {}) {
    return this._call('setWebhook', { url, ...options });
  }

  deleteWebhook(options = {}) {
    return this._call('deleteWebhook', options);
  }

  // ===== Stickers, Games, Payments, etc. =====
  sendInvoice(chat_id, title, description, payload, provider_token, currency, prices, options = {}) {
    return this._call('sendInvoice', {
      chat_id, title, description, payload, provider_token, currency, prices, ...options
    });
  }

  // ===== Utilities =====
  async downloadFile(file_path, dest) {
    const url = `https://api.telegram.org/file/bot${this.API_URL.split('bot')[1]}/${file_path}`;
    this.logger.info(`→ [downloadFile] Streaming ${file_path} → ${dest}`);
    const res = await fetch(url);
    if (!res.ok) {
      const msg = `Failed to download file: HTTP ${res.status}`;
      this.logger.error(msg);
      throw new Error(msg);
    }
    return new Promise((resolve, reject) => {
      const fileStream = fs.createWriteStream(dest);
      res.body.pipe(fileStream);
      res.body.on('error', reject);
      fileStream.on('finish', () => {
        this.logger.info(`← [downloadFile] Saved to ${dest}`);
        resolve(dest);
      });
    });
  }
}