// tg/mixin.ts
// Minimal TS mixin helper used only to compose feature classes
// (messaging, files, chatInfo, webhook) into a single TelegramAPI class.

type Constructor<T = {}> = new (...args: any[]) => T;

/**
 * Applies `mixins` onto `Base`, copying prototype methods so instances of
 * the returned class expose every method from Base + all mixins.
 * Only method/getter copying is needed here — state lives in TelegramHttpClient.
 */
export function applyMixins(Base: Constructor, mixins: Constructor[]): void {
  mixins.forEach(mixin => {
    Object.getOwnPropertyNames(mixin.prototype).forEach(name => {
      if (name === 'constructor') return;
      const descriptor = Object.getOwnPropertyDescriptor(mixin.prototype, name);
      if (descriptor) {
        Object.defineProperty(Base.prototype, name, descriptor);
      }
    });
  });
}
