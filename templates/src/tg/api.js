// tg/api.js
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

  /*
  Reaction emoji. Currently, it can be one of:
  “❤”, “👍”, “👎”, “🔥”, “🥰”, “👏”, “😁”, “🤔”, “🤯”, “😱”,
  “🤬”, “😢”, “🎉”, “🤩”, “🤮”, “💩”, “🙏”, “👌”, “🕊”, “🤡”,
  “🥱”, “🥴”, “😍”, “🐳”, “❤‍🔥”, “🌚”, “🌭”, “💯”, “🤣”, “⚡”,
  “🍌”, “🏆”, “💔”, “🤨”, “😐”, “🍓”, “🍾”, “💋”, “🖕”, “😈”,
  “😴”, “😭”, “🤓”, “👻”, “👨‍💻”, “👀”, “🎃”, “🙈”, “😇”, “😨”,
  “🤝”, “✍”, “🤗”, “🫡”, “🎅”, “🎄”, “☃”, “💅”, “🤪”, “🗿”,
  “🆒”, “💘”, “🙉”, “🦄”, “😘”, “💊”, “🙊”, “😎”, “👾”, “🤷‍♂”,
  “🤷”, “🤷‍♀”, “😡”
  */
   /**
   * Use this method to react to a message with an emoji.
   *
   * @param {number|string} chat_id - The ID of the target chat.
   * @param {number} message_id - The ID of the message to react to.
   * @param {string|string[]} reaction - The emoji(s) to send as a reaction. You can provide a single emoji string ("👍") or an array of up to 16 emojis (["👍", "❤️"]).
   * @param {{ is_big?: boolean }} [options] - Optional parameters. Set `is_big: true` to send a large reaction.
   * @returns {Promise<boolean>} - Returns `true` on success.
   *
   * See: https://core.telegram.org/bots/api#setmessagereaction
   */
  setMessageReaction(chat_id, message_id, reaction, options = {}) {
    // The reaction parameter must be a JSON array of reaction objects.
    const reactionArray = Array.isArray(reaction) ? reaction : [reaction];
    const formattedReaction = reactionArray.map(emoji => ({
      type: 'emoji',
      emoji: emoji,
    }));
    
    return this._call('setMessageReaction', {
      chat_id,
      message_id,
      reaction: formattedReaction,
      ...options,
    });
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
  /**
   * Generate an additional invite link for a chat/channel (supergroups/channels only)
   * 
   * @param {number|string} chat_id - Target chat or channel ID
   * @param {object} options - All supported Telegram parameters:
   *   - name: string (0-32 chars)
   *   - expire_date: number (Unix timestamp, when link expires)
   *   - member_limit: number (1-99999, max users who can join)
   *   - creates_join_request: boolean (if true, users must be approved)
   * @returns {Promise<object>} - Invite link object
   * 
   * See: https://core.telegram.org/bots/api#createchatinvitelink
   */
  createChatInviteLink(chat_id, options = {}) {
    return this._call('createChatInviteLink', { chat_id, ...options });
  }
  /**
   * Returns a list of all active and revoked invite links for a chat.
   * Your bot must be an admin with `can_invite_users` privilege.
   * https://core.telegram.org/bots/api#getchatinvitelinks
   *
   * @param {number|string} chat_id - The target group/channel ID
   * @param {object} [options] - Optional: { limit, offset, invite_link (specific link), ... }
   * @returns {Promise<object[]>} - List of invite link objects
   */
  getChatInviteLinks(chat_id, options = {}) {
    return this._call('getChatInviteLinks', { chat_id, ...options });
  }

    /**
   * Check the status of a specific invite link (must belong to the chat)
   * @param {number|string} chat_id
   * @param {string} targetLink - full invite link (e.g. https://t.me/+abc123)
   * @returns {Promise<'revoked' | 'expired' | 'active' | 'not_found'>}
   */
  async findInviteLinkStatus(chat_id, targetLink) {
    const links = await this.getChatInviteLinks(chat_id);
    const now = Math.floor(Date.now() / 1000);

    const match = links.find(l => l.invite_link === targetLink);
    if (!match) return 'not_found';
    if (match.is_revoked) return 'revoked';
    if (match.expire_date && match.expire_date < now) return 'expired';
    if (match.member_limit && match.member_count >= match.member_limit) return 'expired';
    return 'active';
  }

  /**
   * Revoke a chat invite link (makes the link invalid)
   * https://core.telegram.org/bots/api#revokechatinvitelink
   * @param {number|string} chat_id
   * @param {string} invite_link — The invite link to revoke
   */
  revokeChatInviteLink(chat_id, invite_link) {
    return this._call('revokeChatInviteLink', { chat_id, invite_link });
  }
  /**
   * @param {number|string} chat_id
   * @param {string} invite_link — the invite link to edit
   * @param {{ 
   *   name?: string,
   *   expire_date?: number,
   *   member_limit?: number,
   *   creates_join_request?: boolean
   * }} [options]
   */
  editChatInviteLink(chat_id, invite_link, options = {}) {
    return this._call('editChatInviteLink', { chat_id, invite_link, ...options });
  }

  /**
   * Check if a user is a member of a chat/channel
   * https://core.telegram.org/bots/api#getchatmember
   * Returns the member status, or throws if not found
   * @param {number|string} chat_id
   * @param {number} user_id
   * @returns {Promise<object>} Telegram chat member object (see docs)
   */
  async isUserInChat(chat_id, user_id) {
    try {
      const member = await this.getChatMember(chat_id, user_id);
      // member.status can be 'creator', 'administrator', 'member', 'restricted', 'left', 'kicked'
      // 'left' and 'kicked' mean they're not present
      return !['left', 'kicked'].includes(member.status);
    } catch (err) {
      this.logger.warn(`[isUserInChat] Error:`, err);
      return false;
    }
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
