import EventEmitter from 'events';

export class TelegramQueue extends EventEmitter {
  constructor({ initialRate = 25, minRate = 3, maxRate = 28 }) {
    super();
    this.queue = [];
    this.currentRate = initialRate;
    this.minRate = minRate;
    this.maxRate = maxRate;
    this.pausedUntil = 0;
    this.isProcessing = false;
  }

  async enqueue(fn, args, chatId) {
    return new Promise((resolve, reject) => {
      this.queue.push({ fn, args, chatId, resolve, reject });
      this.process();
    });
  }

  setRate(rate) {
    this.currentRate = Math.max(this.minRate, Math.min(this.maxRate, rate));
  }

  async process() {
    if (this.isProcessing) return;
    this.isProcessing = true;
    while (this.queue.length) {
      const now = Date.now();
      if (now < this.pausedUntil) {
        await new Promise(r => setTimeout(r, this.pausedUntil - now));
        continue;
      }
      const { fn, args, chatId, resolve, reject } = this.queue.shift();
      try {
        const result = await fn(...args);
        resolve(result);
        if (this.queue.length < 8) this.setRate(this.currentRate + 0.3);
      } catch (err) {
        const msg = String(err);
        const m = msg.match(/retry after (\d+)/i);
        if (m) {
          const wait = Number(m[1]) * 1000;
          this.pausedUntil = Date.now() + wait;
          this.setRate(this.currentRate * 0.7);
          this.queue.unshift({ fn, args, chatId, resolve, reject });
          await new Promise(r => setTimeout(r, wait));
          continue;
        }
        reject(err);
      }
      await new Promise(r => setTimeout(r, 1000 / this.currentRate));
    }
    this.isProcessing = false;
  }
}
