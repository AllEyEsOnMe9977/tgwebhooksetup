// tg/files.ts
// File detection/extraction from messages+updates, and physical download.

import fs from 'fs';
import { TelegramHttpClient } from './httpClient';
import type {
  TelegramMessage,
  TelegramUpdate,
  FileInfo,
  FileInfoWithDownload,
  GetFileResult,
} from './types';

export class TelegramFiles extends TelegramHttpClient {
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
