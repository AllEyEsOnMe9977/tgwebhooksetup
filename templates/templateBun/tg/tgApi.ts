// tg/api.ts
import fetch, { Response } from 'node-fetch';
import fs from 'fs';

/** Minimal logger interface (compatible with console). */
export interface Logger {
  info: (...args: any[]) => void;
  warn: (...args: any[]) => void;
  error: (...args: any[]) => void;
}

export interface TelegramAPIOptions {
  logger?: Logger;
}

/** Generic key/value payload sent to Telegram methods. */
export type TelegramParams = Record<string, unknown>;

/** Shape of Telegram's raw JSON envelope: { ok, result } or { ok:false, error_code, description, parameters }. */
interface TelegramResponseEnvelope<T = unknown> {
  ok: boolean;
  result?: T;
  error_code?: number;
  description?: string;
  parameters?: { retry_after?: number };
}

export interface TelegramMessage {
  message_id: number;
  forward_from?: unknown;
  forward_from_chat?: unknown;
  document?: { file_id: string; file_name?: string; mime_type?: string };
  photo?: Array<{ file_id: string }>;
  video?: { file_id: string; file_name?: string; mime_type?: string };
  audio?: { file_id: string; file_name?: string; mime_type?: string };
  voice?: { file_id: string; mime_type?: string };
  video_note?: { file_id: string };
  animation?: { file_id: string; file_name?: string; mime_type?: string };
  sticker?: { file_id: string; is_video?: boolean; is_animated?: boolean };
  [key: string]: unknown;
}

export interface TelegramUpdate {
  message?: TelegramMessage;
  edited_message?: TelegramMessage;
  channel_post?: TelegramMessage;
  edited_channel_post?: TelegramMessage;
  [key: string]: unknown;
}

export interface FileInfo {
  type: string;
  file_id: string;
  file_name?: string | null;
  mime_type?: string | null;
  message_id: number;
}

export interface FileInfoWithDownload extends FileInfo {
  file_path?: string | null;
  download_url?: string | null;
}

export interface ChatInviteLink {
  invite_link: string;
  is_revoked?: boolean;
  expire_date?: number;
  member_limit?: number;
  member_count?: number;
  [key: string]: unknown;
}

export interface ChatMember {
  status: 'creator' | 'administrator' | 'member' | 'restricted' | 'left' | 'kicked';
  [key: string]: unknown;
}

export interface GetFileResult {
  file_id: string;
  file_unique_id: string;
  file_size?: number;
  file_path?: string;
}

export interface GetMeResult {
  id: number;
  is_bot: boolean;
  username: string;
  [key: string]: unknown;
}

// ===== Rich Messages Interfaces =====

export interface RichTextButton {
  text: string;
  style?: 'primary' | 'success' | 'danger' | 'link';
  url?: string;
  callback_data?: string;
}

export interface RichTableCell {
  type: 'text';
  text: string | { type: 'button'; button: RichTextButton };
}

export interface RichBlockPhoto {
  type: 'photo';
  photo: {
    type: 'photo';
    media: string;
  };
}

export interface RichBlockParagraph {
  type: 'paragraph';
  text: string;
}

export interface RichBlockExpandableBlockquote {
  type: 'expandable_blockquote';
  text: string;
}

export interface RichBlockTable {
  type: 'table';
  is_bordered?: boolean;
  is_striped?: boolean;
  is_compact?: boolean;
  cells: RichTableCell[][];
}

export interface RichBlockButtons {
  type: 'buttons';
  align?: 'left' | 'center' | 'right';
  buttons: Array<{
    text: string;
    url?: string;
    callback_data?: string;
  }>;
}

export type InputRichBlock =
  | RichBlockPhoto
  | RichBlockParagraph
  | RichBlockExpandableBlockquote
  | RichBlockTable
  | RichBlockButtons;

export interface InputRichMessage {
  blocks: InputRichBlock[];
}

export class TelegramAPI {
  private readonly API_URL: string;
  private readonly logger: Logger;
  private _meCache?: GetMeResult;

  /**
   * @param botToken — your bot's token
   * @param options
   */
  constructor(botToken: string, { logger = console }: TelegramAPIOptions = {}) {
    if (!botToken) throw new Error('Bot token is required');
    this.API_URL = `https://api.telegram.org/bot${botToken}`;
    this.logger = logger;
  }

  /**
   * Generic GET/POST wrapper with retries, rate-limit handling, and logging.
   */
  private async _call<T = unknown>(
    method: string,
    data: TelegramParams = {},
    isPost: boolean = true
  ): Promise<T> {
    const url = `${this.API_URL}/${method}`;
    const maxNetworkRetries = 3;
    let networkAttempts = 0;

    // Build fetch options
    const options: Parameters<typeof fetch>[1] = isPost
      ? {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(data),
        }
      : { method: 'GET' };
    const requestUrl = isPost
      ? url
      : `${url}?${new URLSearchParams(data as Record<string, string>)}`;

    // Inside _call(method, data = {}, isPost = true)
    while (true) {
      try {
        this.logger.info(`→ [${method}] Request`, { url: requestUrl, payload: data });
        const res: Response = await fetch(requestUrl, options);
        const text = await res.text().catch(() => null);

        let json: TelegramResponseEnvelope<T>;
        try {
          json = text ? (JSON.parse(text) as TelegramResponseEnvelope<T>) : ({} as TelegramResponseEnvelope<T>);
        } catch (e) {
          throw new Error(`Invalid JSON response (${res.status}): ${text}`);
        }

        // ---------- HTTP-level errors ----------
        if (!res.ok) {
          const desc = json?.description || '';
          // 429: respect retry-after as you already do
          if (res.status === 429) {
            const retryAfter =
              json?.parameters?.retry_after ||
              parseInt(res.headers.get('retry-after') || '', 10) ||
              1;
            this.logger.warn(`← [${method}] Rate limited. Retrying in ${retryAfter}s`, {
              status: res.status, error: json,
            });
            await new Promise(r => setTimeout(r, retryAfter * 1000));
            continue;
          }

          // 👇 SWALLOW benign 400s
          // (1) Stale callback ACKs are harmless → treat as success/no-op
          if (
            method === 'answerCallbackQuery' &&
            res.status === 400 &&
            /query is too old|query ID is invalid/i.test(desc)
          ) {
            this.logger.warn(`← [${method}] Stale callback (ignored): ${desc}`);
            return true as unknown as T; // behave as success
          }

          // (2) No-op edits → treat as success
          if (
            (method === 'editMessageText' || method === 'editMessageReplyMarkup') &&
            res.status === 400 &&
            /message is not modified/i.test(desc)
          ) {
            this.logger.info(`← [${method}] No-op edit (ignored)`);
            return (json?.result ?? true) as T; // behave as success
          }

          this.logger.error(`← [${method}] HTTP error`, { status: res.status, body: json || text });
          throw new Error(`HTTP ${res.status}: ${desc || res.statusText}`);
        }

        // ---------- Bot API-level errors (ok:false with 200) ----------
        if (json.ok === false) {
          const code = json.error_code;
          const desc = json.description || '';

          // 429 flood-wait path (as you have)
          if (json.parameters?.retry_after) {
            const wait = json.parameters.retry_after;
            this.logger.warn(`← [${method}] Flood wait ${wait}s`, { error_code: code, description: desc });
            await new Promise(r => setTimeout(r, wait * 1000));
            continue;
          }

          // 👇 SWALLOW benign bot errors as well (if they come via ok:false/200)
          if (
            method === 'answerCallbackQuery' &&
            code === 400 &&
            /query is too old|query ID is invalid/i.test(desc)
          ) {
            this.logger.warn(`← [${method}] Stale callback (ignored): ${desc}`);
            return true as unknown as T;
          }
          if (
            (method === 'editMessageText' || method === 'editMessageReplyMarkup') &&
            code === 400 &&
            /message is not modified/i.test(desc)
          ) {
            this.logger.info(`← [${method}] No-op edit (ignored)`);
            return (json?.result ?? true) as T;
          }

          this.logger.error(`← [${method}] Telegram API error ${code}`, { description: desc, data });
          throw new Error(`Telegram API Error ${code}: ${desc}`);
        }

        this.logger.info(`← [${method}] Success`, { result: json.result });
        return json.result as T;
      } catch (err: any) {
        // Network or parsing failures
        const isNetworkError =
          err?.type === 'system' ||
          /ECONNRESET|ENOTFOUND|ETIMEDOUT/.test(err?.message || '');
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

  // ===== User & Chat Info =====
  getMe(): Promise<GetMeResult> {
    return this._call<GetMeResult>('getMe', {}, false);
  }

  // add this method to the class
  async getBotUsername(): Promise<string> {
    if (!this._meCache) {
      this._meCache = await this.getMe(); // returns { id, is_bot, username, ... }
    }
    return this._meCache.username;
  }

  /**
   * Generate an additional invite link for a chat/channel (supergroups/channels only)
   *
   * @param chat_id - Target chat or channel ID
   * @param options - All supported Telegram parameters:
   *   - name: string (0-32 chars)
   *   - expire_date: number (Unix timestamp, when link expires)
   *   - member_limit: number (1-99999, max users who can join)
   *   - creates_join_request: boolean (if true, users must be approved)
   * @returns Invite link object
   *
   * See: https://core.telegram.org/bots/api#createchatinvitelink
   */
  createChatInviteLink(chat_id: number | string, options: TelegramParams = {}) {
    return this._call<ChatInviteLink>('createChatInviteLink', { chat_id, ...options });
  }

  /**
   * Returns a list of all active and revoked invite links for a chat.
   * Your bot must be an admin with `can_invite_users` privilege.
   * https://core.telegram.org/bots/api#getchatinvitelinks
   *
   * @param chat_id - The target group/channel ID
   * @param options - Optional: { limit, offset, invite_link (specific link), ... }
   * @returns List of invite link objects
   */
  getChatInviteLinks(chat_id: number | string, options: TelegramParams = {}) {
    return this._call<ChatInviteLink[]>('getChatInviteLinks', { chat_id, ...options });
  }

  /**
   * Check the status of a specific invite link (must belong to the chat)
   * @param chat_id
   * @param targetLink - full invite link (e.g. https://t.me/+abc123)
   */
  async findInviteLinkStatus(
    chat_id: number | string,
    targetLink: string
  ): Promise<'revoked' | 'expired' | 'active' | 'not_found'> {
    const links = await this.getChatInviteLinks(chat_id);
    const now = Math.floor(Date.now() / 1000);

    const match = links.find(l => l.invite_link === targetLink);
    if (!match) return 'not_found';
    if (match.is_revoked) return 'revoked';
    if (match.expire_date && match.expire_date < now) return 'expired';
    if (match.member_limit && match.member_count !== undefined && match.member_count >= match.member_limit) return 'expired';
    return 'active';
  }

  /**
   * Revoke a chat invite link (makes the link invalid)
   * https://core.telegram.org/bots/api#revokechatinvitelink
   * @param chat_id
   * @param invite_link — The invite link to revoke
   */
  revokeChatInviteLink(chat_id: number | string, invite_link: string) {
    return this._call('revokeChatInviteLink', { chat_id, invite_link });
  }

  /**
   * @param chat_id
   * @param invite_link — the invite link to edit
   * @param options
   */
  editChatInviteLink(
    chat_id: number | string,
    invite_link: string,
    options: {
      name?: string;
      expire_date?: number;
      member_limit?: number;
      creates_join_request?: boolean;
    } = {}
  ) {
    return this._call('editChatInviteLink', { chat_id, invite_link, ...options });
  }

  /**
   * Check if a user is a member of a chat/channel
   * https://core.telegram.org/bots/api#getchatmember
   * Returns the member status, or throws if not found
   * @param chat_id
   * @param user_id
   */
  async isUserInChat(chat_id: number | string, user_id: number): Promise<boolean> {
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

  getUserProfilePhotos(user_id: number, options: TelegramParams = {}) {
    return this._call('getUserProfilePhotos', { user_id, ...options }, false);
  }

  getChat(chat_id: number | string) {
    return this._call('getChat', { chat_id }, false);
  }

  getChatAdministrators(chat_id: number | string) {
    return this._call('getChatAdministrators', { chat_id }, false);
  }

  getChatMember(chat_id: number | string, user_id: number): Promise<ChatMember> {
    return this._call<ChatMember>('getChatMember', { chat_id, user_id }, false);
  }

  getChatMembersCount(chat_id: number | string) {
    return this._call('getChatMemberCount', { chat_id }, false);
  }

  // ===== Updates (Polling) =====
  getUpdates(options: TelegramParams = {}) {
    return this._call('getUpdates', options, false);
  }

  /**
   * Check if a Telegram message object is forwarded.
   * A forwarded message has either `forward_from` (user) or `forward_from_chat` (channel/group).
   *
   * @param message - The Telegram message object
   * @returns true if forwarded, false otherwise
   */
  isForwardedMessage(message: TelegramMessage | undefined | null): boolean {
    if (!message || typeof message !== 'object') return false;
    return Boolean(message.forward_from || message.forward_from_chat);
  }

  /**
   * Check if an update contains a forwarded message.
   *
   * @param update - Telegram Update object
   * @returns true if forwarded, false otherwise
   */
  isForwardedUpdate(update: TelegramUpdate): boolean {
    const msg = update?.message || update?.edited_message || update?.channel_post || update?.edited_channel_post;
    return this.isForwardedMessage(msg);
  }

  // ===== Files =====
  getFile(file_id: string): Promise<GetFileResult> {
    // Use GET for getFile (returns { file_id, file_unique_id, file_size, file_path })
    return this._call<GetFileResult>('getFile', { file_id }, false);
  }

  /**
   * Build a public download URL from a Telegram file_path.
   */
  private _fileDownloadUrl(file_path: string): string {
    // this.API_URL = https://api.telegram.org/bot<token>
    const token = this.API_URL.split('/bot')[1]; // <token>
    return `https://api.telegram.org/file/bot${token}/${file_path}`;
  }

  /**
   * Extract file info (type, file_id, file_name, mime_type) from a *message* object.
   * Works for photo, document, video, audio, voice, video_note, animation, sticker.
   * Returns null for text-only messages.
   *
   * @param message - Telegram message object (update.message or update.edited_message)
   */
  extractFileInfoFromMessage(message: TelegramMessage | undefined | null): FileInfo | null {
    if (!message) return null;

    // Order matters: check the mutually exclusive types first
    if (message.document) {
      return {
        type: 'document',
        file_id: message.document.file_id,
        file_name: message.document.file_name ?? null,
        mime_type: message.document.mime_type ?? null,
        message_id: message.message_id,
      };
    }
    if (message.photo && Array.isArray(message.photo) && message.photo.length) {
      // choose the largest size (last element)
      const largest = message.photo[message.photo.length - 1];
      return {
        type: 'photo',
        file_id: largest.file_id,
        file_name: null,
        mime_type: null,
        message_id: message.message_id,
      };
    }
    if (message.video) {
      return {
        type: 'video',
        file_id: message.video.file_id,
        file_name: message.video.file_name ?? null,
        mime_type: message.video.mime_type ?? null,
        message_id: message.message_id,
      };
    }
    if (message.audio) {
      return {
        type: 'audio',
        file_id: message.audio.file_id,
        file_name: message.audio.file_name ?? null,
        mime_type: message.audio.mime_type ?? null,
        message_id: message.message_id,
      };
    }
    if (message.voice) {
      return {
        type: 'voice',
        file_id: message.voice.file_id,
        file_name: null,
        mime_type: message.voice.mime_type ?? null,
        message_id: message.message_id,
      };
    }
    if (message.video_note) {
      return {
        type: 'video_note',
        file_id: message.video_note.file_id,
        file_name: null,
        mime_type: null,
        message_id: message.message_id,
      };
    }
    if (message.animation) {
      // "GIF" in Telegram terms
      return {
        type: 'animation',
        file_id: message.animation.file_id,
        file_name: message.animation.file_name ?? null,
        mime_type: message.animation.mime_type ?? null,
        message_id: message.message_id,
      };
    }
    if (message.sticker) {
      // Stickers don't expose mime_type; you can derive from flags
      const kind = message.sticker.is_video
        ? 'sticker_video'
        : message.sticker.is_animated
        ? 'sticker_animated'
        : 'sticker_static';
      return {
        type: kind,
        file_id: message.sticker.file_id,
        file_name: null,
        mime_type: null,
        message_id: message.message_id,
      };
    }

    // Not a file-carrying message
    return null;
  }

  /**
   * Detect file type from an *update* and (optionally) resolve to download URL.
   * If a file exists: returns { type, file_id, file_name, mime_type, message_id, file_path?, download_url? }.
   * If text-only: returns null.
   *
   * @param update - Telegram Update
   * @param resolveDownload - If true, calls getFile to fetch file_path and builds download URL
   */
  async detectFileFromUpdate(
    update: TelegramUpdate,
    resolveDownload: boolean = false
  ): Promise<FileInfoWithDownload | null> {
    const msg = update?.message || update?.edited_message || update?.channel_post || update?.edited_channel_post;
    const base = this.extractFileInfoFromMessage(msg);
    if (!base) return null;

    if (!resolveDownload) return base;

    const info = await this.getFile(base.file_id);
    const file_path = info?.file_path || null;
    const download_url = file_path ? this._fileDownloadUrl(file_path) : null;

    return { ...base, file_path, download_url };
  }

  setWebhook(url: string, options: TelegramParams = {}) {
    return this._call('setWebhook', { url, ...options });
  }

  deleteWebhook(options: TelegramParams = {}) {
    return this._call('deleteWebhook', options);
  }

  // ===== Stickers, Games, Payments, etc. =====
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

  // ===== Utilities =====
  async downloadFile(file_path: string, dest: string): Promise<string> {
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