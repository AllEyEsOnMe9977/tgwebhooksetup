// tg/httpClient.ts
// Base class: holds the bot token, logger, and the low-level _call() method
// that every feature module (messaging, files, chatInfo, webhook) relies on.
// Retry, rate-limit, and benign-error-swallowing logic lives here ONLY.

import type { Logger, TelegramAPIOptions, TelegramParams, TelegramResponseEnvelope } from './types';

export class TelegramHttpClient {
  protected readonly API_URL: string;
  protected readonly logger: Logger;
  protected readonly debug: boolean;

  /**
   * @param botToken — your bot's token
   * @param options
   */
  constructor(botToken: string, { logger = console }: TelegramAPIOptions = {}) {
    if (!botToken) throw new Error('Bot token is required');
    this.API_URL = `https://api.telegram.org/bot${botToken}`;
    this.logger = logger;
    // Verbose mode: full request/response logging, including quiet getUpdates
    // polls. Off by default to keep journald readable; set DEBUG_TG_API=1
    // (or "true") in .env to restore full visibility while debugging.
    this.debug = process.env.DEBUG_TG_API === '1' || process.env.DEBUG_TG_API === 'true';
  }

  /**
   * Compact a payload/result for logging: single-line JSON, truncated so
   * large arrays (allowed_updates, media groups, etc.) don't flood the console.
   */
  protected _compactPayload(value: unknown, maxLen: number = 300): string {
    if (value === undefined) return '';
    let str: string;
    try {
      str = JSON.stringify(value);
    } catch {
      str = String(value);
    }
    return str.length > maxLen ? `${str.slice(0, maxLen)}…(${str.length} chars)` : str;
  }

  /**
   * Generic GET/POST wrapper with retries, rate-limit handling, and logging.
   */
  protected async _call<T = unknown>(
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
        // Don't spam logs every 30s for empty long-polls — only log when there's
        // something to say (non-getUpdates calls, or getUpdates with actual updates).
        // DEBUG_TG_API=1 overrides this and logs every request in full.
        if (this.debug) {
          this.logger.info(`→ [${method}] Request`, { url: requestUrl, payload: data });
        } else if (method !== 'getUpdates') {
          this.logger.info(`→ [${method}]`, this._compactPayload(data));
        }
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

        if (this.debug) {
          this.logger.info(`← [${method}] Success`, { result: json.result });
        } else if (method === 'getUpdates') {
          const count = Array.isArray(json.result) ? json.result.length : 0;
          if (count > 0) this.logger.info(`← [getUpdates] ${count} update(s)`);
          // else: silent — this is the expected steady-state case, not worth a log line
        } else {
          this.logger.info(`← [${method}] OK`, this._compactPayload(json.result));
        }
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
}
