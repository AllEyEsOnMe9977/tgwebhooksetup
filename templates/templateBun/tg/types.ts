// tg/types.ts
// All shared types/interfaces for the Telegram API client.
// Pure type definitions — no runtime logic lives here.

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
export interface TelegramResponseEnvelope<T = unknown> {
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
