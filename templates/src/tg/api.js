import fetch from 'node-fetch';

export class TelegramAPI {
  constructor(botToken) {
    if (!botToken) throw new Error('Bot token is required');
    this.API_URL = `https://api.telegram.org/bot${botToken}`;
  }

  // Generic GET or POST API call
  async _call(method, data = {}, isPost = true) {
    const url = `${this.API_URL}/${method}`;
    const options = isPost
      ? {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(data),
        }
      : {
          method: 'GET',
        };

    try {
      const res = await fetch(
        isPost ? url : `${url}?${new URLSearchParams(data)}`,
        options
      );
      const json = await res.json();
      if (!json.ok) throw new Error(json.description || 'Telegram API Error');
      return json.result;
    } catch (err) {
      throw err;
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
    const res = await fetch(url);
    const fileStream = require('fs').createWriteStream(dest);
    await new Promise((resolve, reject) => {
      res.body.pipe(fileStream);
      res.body.on('error', reject);
      fileStream.on('finish', resolve);
    });
    return dest;
  }
}
