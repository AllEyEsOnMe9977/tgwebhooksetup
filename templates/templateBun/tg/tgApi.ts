// tg/tgApi.ts
// Public entry point. Composes feature modules (messaging, chatInfo, files,
// webhook) into a single TelegramAPI class so existing call sites
// (`new TelegramAPI(token).sendMessage(...)`) keep working unchanged.
//
// Split rationale: each concern now lives in its own file under tg/ for
// easier maintenance (messaging.ts, chatInfo.ts, files.ts, webhook.ts),
// while httpClient.ts holds the shared request/retry/logging core.

import { TelegramHttpClient } from './httpClient';
import { TelegramMessaging } from './messaging';
import { TelegramChatInfo } from './chatInfo';
import { TelegramFiles } from './files';
import { TelegramWebhook } from './webhook';
import { applyMixins } from './mixin';

import type { TelegramAPIOptions } from './types';

// Re-export all types so `import { FileInfo } from './tg/tgApi'` etc. still works.
export * from './types';

/**
 * TelegramAPI — combines TelegramHttpClient (base: constructor + _call)
 * with TelegramMessaging, TelegramChatInfo, TelegramFiles, TelegramWebhook.
 * Usage is unchanged: `new TelegramAPI(botToken, { logger }).sendMessage(...)`.
 */
export class TelegramAPI extends TelegramHttpClient {
  constructor(botToken: string, options: TelegramAPIOptions = {}) {
    super(botToken, options);
  }
}

// Merge feature-module methods onto TelegramAPI's prototype.
applyMixins(TelegramAPI, [TelegramMessaging, TelegramChatInfo, TelegramFiles, TelegramWebhook]);

// TypeScript needs an explicit interface merge so it knows about the
// mixed-in methods at compile time (applyMixins only does this at runtime).
export interface TelegramAPI
  extends TelegramMessaging,
    TelegramChatInfo,
    TelegramFiles,
    TelegramWebhook {}