// tg/webhook.ts
// Webhook management and long-polling.

import { TelegramHttpClient } from './httpClient';
import type { TelegramParams } from './types';

export class TelegramWebhook extends TelegramHttpClient {
  // ===== Updates (Polling) =====
  getUpdates(options: TelegramParams = {}) {
    return this._call('getUpdates', options, false);
  }

  setWebhook(url: string, options: TelegramParams = {}) {
    return this._call('setWebhook', { url, ...options });
  }

  deleteWebhook(options: TelegramParams = {}) {
    return this._call('deleteWebhook', options);
  }
}
