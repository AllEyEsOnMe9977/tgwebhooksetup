// tg/messaging.ts
// Sending, editing, deleting messages; reactions; callback queries; chat actions.

import { TelegramHttpClient } from './httpClient';
import type { TelegramParams, InputRichMessage } from './types';

export class TelegramMessaging extends TelegramHttpClient {
  // ===== Messaging =====
  sendMessage(chat_id: number | string, text: string, options: TelegramParams = {}) {
    return this._call('sendMessage', { chat_id, text, ...options });
  }

  /**
   * Sends a structured rich message using modular JSON blocks.
   * @param chat_id Target chat ID.
   * @param rich_message The InputRichMessage object containing an array of blocks.
   * @param options Additional Telegram parameters.
   */
  sendRichMessage(chat_id: number | string, rich_message: InputRichMessage, options: TelegramParams = {}) {
    return this._call('sendRichMessage', { chat_id, rich_message, ...options });
  }

  /**
   * Sends a temporary streaming draft of a rich message.
   * @param chat_id Target chat ID.
   * @param rich_message The InputRichMessage object containing an array of blocks.
   * @param options Additional Telegram parameters.
   */
  sendRichMessageDraft(chat_id: number | string, rich_message: InputRichMessage, options: TelegramParams = {}) {
    return this._call('sendRichMessageDraft', { chat_id, rich_message, ...options });
  }

  forwardMessage(chat_id: number | string, from_chat_id: number | string, message_id: number, options: TelegramParams = {}) {
    return this._call('forwardMessage', { chat_id, from_chat_id, message_id, ...options });
  }

  copyMessage(chat_id: number | string, from_chat_id: number | string, message_id: number, options: TelegramParams = {}) {
    return this._call('copyMessage', { chat_id, from_chat_id, message_id, ...options });
  }

  sendPhoto(chat_id: number | string, photo: string, options: TelegramParams = {}) {
    return this._call('sendPhoto', { chat_id, photo, ...options });
  }

  sendDocument(chat_id: number | string, document: string, options: TelegramParams = {}) {
    return this._call('sendDocument', { chat_id, document, ...options });
  }

  sendAudio(chat_id: number | string, audio: string, options: TelegramParams = {}) {
    return this._call('sendAudio', { chat_id, audio, ...options });
  }

  sendVideo(chat_id: number | string, video: string, options: TelegramParams = {}) {
    return this._call('sendVideo', { chat_id, video, ...options });
  }

  sendMediaGroup(chat_id: number | string, media: unknown[], options: TelegramParams = {}) {
    return this._call('sendMediaGroup', { chat_id, media, ...options });
  }

  sendLocation(chat_id: number | string, latitude: number, longitude: number, options: TelegramParams = {}) {
    return this._call('sendLocation', { chat_id, latitude, longitude, ...options });
  }

  sendContact(chat_id: number | string, phone_number: string, first_name: string, options: TelegramParams = {}) {
    return this._call('sendContact', { chat_id, phone_number, first_name, ...options });
  }

  sendSticker(chat_id: number | string, sticker: string, options: TelegramParams = {}) {
    return this._call('sendSticker', { chat_id, sticker, ...options });
  }

  sendAnimation(chat_id: number | string, animation: string, options: TelegramParams = {}) {
    return this._call('sendAnimation', { chat_id, animation, ...options });
  }

  /*
  Reaction emoji. Currently, it can be one of:
  "❤", "👍", "👎", "🔥", "🥰", "👏", "😁", "🤔", "🤯", "😱",
  "🤬", "😢", "🎉", "🤩", "🤮", "💩", "🙏", "👌", "🕊", "🤡",
  "🥱", "🥴", "😍", "🐳", "❤‍🔥", "🌚", "🌭", "💯", "🤣", "⚡",
  "🍌", "🏆", "💔", "🤨", "😐", "🍓", "🍾", "💋", "🖕", "😈",
  "😴", "😭", "🤓", "👻", "👨‍💻", "👀", "🎃", "🙈", "😇", "😨",
  "🤝", "✍", "🤗", "🫡", "🎅", "🎄", "☃", "💅", "🤪", "🗿",
  "🆒", "💘", "🙉", "🦄", "😘", "💊", "🙊", "😎", "👾", "🤷‍♂",
  "🤷", "🤷‍♀", "😡"
  */
  /**
   * Use this method to react to a message with an emoji.
   *
   * @param chat_id - The ID of the target chat.
   * @param message_id - The ID of the message to react to.
   * @param reaction - The emoji(s) to send as a reaction. You can provide a single emoji string ("👍") or an array of up to 16 emojis (["👍", "❤️"]).
   * @param options - Optional parameters. Set `is_big: true` to send a large reaction.
   * @returns Returns `true` on success.
   *
   * See: https://core.telegram.org/bots/api#setmessagereaction
   */
  setMessageReaction(
    chat_id: number | string,
    message_id: number,
    reaction: string | string[],
    options: { is_big?: boolean } & TelegramParams = {}
  ) {
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

  editMessageText(chat_id: number | string, message_id: number, text: string, options: TelegramParams = {}) {
    return this._call('editMessageText', { chat_id, message_id, text, ...options });
  }

  deleteMessage(chat_id: number | string, message_id: number) {
    return this._call('deleteMessage', { chat_id, message_id });
  }

  // ===== Keyboard & UI =====
  answerCallbackQuery(callback_query_id: string, options: TelegramParams = {}) {
    return this._call('answerCallbackQuery', { callback_query_id, ...options });
  }

  sendChatAction(chat_id: number | string, action: string) {
    return this._call('sendChatAction', { chat_id, action });
  }

  // ===== Payments =====
  sendInvoice(
    chat_id: number | string,
    title: string,
    description: string,
    payload: string,
    provider_token: string,
    currency: string,
    prices: Array<{ label: string; amount: number }>,
    options: TelegramParams = {}
  ) {
    return this._call('sendInvoice', {
      chat_id, title, description, payload, provider_token, currency, prices, ...options
    });
  }
}
