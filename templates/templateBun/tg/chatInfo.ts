// tg/chatInfo.ts
// User/chat metadata, invite links, membership checks.

import { TelegramHttpClient } from './httpClient';
import type { TelegramParams, ChatInviteLink, ChatMember, GetMeResult } from './types';

export class TelegramChatInfo extends TelegramHttpClient {
  private _meCache?: GetMeResult;

  // ===== User & Chat Info =====
  getMe(): Promise<GetMeResult> {
    return this._call<GetMeResult>('getMe', {}, false);
  }

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
}
