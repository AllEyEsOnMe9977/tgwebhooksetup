// /tg/queue.js
import EventEmitter from 'events';

let BullMQ, IORedis; // loaded lazily
const REDIS_URL = process.env.REDIS_URL;

// Small helper to normalize function names (handles "bound sendMessage")
const getFnName = (fn) => {
  const raw = (fn && fn.name) || '';
  return raw.startsWith('bound ') ? raw.slice(6) : raw;
};

// --------------------------- Redis-backed queue ---------------------------
class RedisTelegramQueue extends EventEmitter {
  constructor({
    initialRate = 25,
    minRate = 3,
    maxRate = 28,
    maxConcurrent = 20,
    rateLimitWindow = 1000
  } = {}) {
    super();
    this.currentRate = initialRate;
    this.minRate = minRate;
    this.maxRate = maxRate;
    this.maxConcurrent = maxConcurrent;
    this.rateLimitWindow = rateLimitWindow;

    this.contexts = new Map(); // name -> object (e.g., 'tg' -> TelegramAPI instance)
    this.started = false;
    this.pendingResolves = new Map(); // jobId -> {resolve, reject}
    this.warnedAnonymous = false;

    this._init();
  }

  async _init() {
    const { Queue, Worker, QueueEvents, JobsOptions } = (BullMQ ??= await import('bullmq'));
    const Redis = (IORedis ??= (await import('ioredis')).default);

    this.connection = new Redis(REDIS_URL, { maxRetriesPerRequest: null });
    this.queue = new Queue('telegram-tasks', {
      connection: this.connection,
      defaultJobOptions: {
        attempts: 8,
        removeOnComplete: 1000,
        removeOnFail: 1000,
        backoff: { type: 'custom' } // use custom strategy below
      }
    });

    this.queueEvents = new QueueEvents('telegram-tasks', { connection: this.connection });
    this.queueEvents.on('completed', ({ jobId, returnvalue }) => {
      const p = this.pendingResolves.get(jobId);
      if (p) { p.resolve(returnvalue); this.pendingResolves.delete(jobId); }
    });
    this.queueEvents.on('failed', ({ jobId, failedReason }) => {
      const p = this.pendingResolves.get(jobId);
      if (p) { p.reject(new Error(failedReason)); this.pendingResolves.delete(jobId); }
    });

    // Worker
    this.worker = new Worker(
      'telegram-tasks',
      async (job) => {
        // Per-second rate limiter (simple token bucket using Redis INCR/EXPIRE)
        await this._takeRateToken();

        const { fnName, args } = job.data;
        const fn = this._resolveFunction(fnName);
        if (!fn) throw new Error(`No function resolver for "${fnName}"`);
        try {
          const result = await fn(...args);
          // adaptively nudge the rate up on success
          if (await this._queueSize() < 8) this.setRate(this.currentRate + 0.3);
          return result;
        } catch (err) {
          // Handle Telegram 429 "retry after X"
          const msg = String(err);
          const retryMatch = msg.match(/retry after (\d+)/i);
          if (retryMatch) {
            const waitMs = Number(retryMatch[1]) * 1000;
            // Lower the rate a bit and ask BullMQ to backoff by waitMs
            this.setRate(this.currentRate * 0.7);
            const e = new Error(`Rate limited; backoff ${waitMs}ms`);
            e.backoff = waitMs;
            throw e;
          }
          throw err;
        }
      },
      {
        connection: this.connection,
        concurrency: this.maxConcurrent,
        // Custom backoff reads error.backoff
        settings: {
          backoffStrategies: {
            custom: (_attemptsMade, err) => (err && err.backoff) || 1000
          }
        }
      }
    );

    this.started = true;
  }

  registerContext(name, obj) {
    this.contexts.set(name, obj);
  }

  _resolveFunction(fnName) {
    for (const obj of this.contexts.values()) {
      const candidate = obj?.[fnName];
      if (typeof candidate === 'function') return candidate.bind(obj);
    }
    return null;
  }

  // crude Redis token bucket: limit to currentRate per rateLimitWindow
  async _takeRateToken() {
    const key = `tg:rate:${Math.floor(Date.now() / this.rateLimitWindow)}`;
    const n = await this.connection.incr(key);
    if (n === 1) await this.connection.pexpire(key, this.rateLimitWindow);
    if (n > this.currentRate) {
      // sleep until next window
      const ms = this.rateLimitWindow - (Date.now() % this.rateLimitWindow);
      await new Promise((r) => setTimeout(r, ms));
    }
  }

  async _queueSize() {
    const counts = await this.queue.getJobCounts('waiting', 'delayed');
    return (counts.waiting || 0) + (counts.delayed || 0);
  }

  setRate(rate) {
    this.currentRate = Math.max(this.minRate, Math.min(this.maxRate, rate));
  }

  async enqueue(fn, args, chatId) {
    const fnName = getFnName(fn);
    if (!fnName) {
      if (!this.warnedAnonymous) {
        this.warnedAnonymous = true;
        console.warn(
          '[Queue] Anonymous/arrow function detected. Falling back to in-memory execution for such tasks. Consider passing a named method of a registered context (e.g. tg.sendMessage.bind(tg)).'
        );
      }
      // Fallback: run immediately (non-durable) to avoid breaking callers
      return fn(...args);
    }

    const job = await this.queue.add(fnName, { fnName, args, chatId });
    return await new Promise((resolve, reject) => {
      this.pendingResolves.set(job.id, { resolve, reject });
    });
  }

  async clearQueue() {
    // Clear waiting/delayed jobs; active jobs are not interrupted
    await this.queue.drain(true);
    const counts = await this.queue.getJobCounts('completed', 'failed');
    // Not rejecting pending promises for completed/failed jobs since they’ll emit events
  }

  stop() {
    // Pause queue intake and worker
    return Promise.all([this.queue.pause(), this.worker.pause()]);
  }

  async resume() {
    await this.queue.resume();
    await this.worker.resume();
  }

  async getStatus() {
    const counts = await this.queue.getJobCounts(
      'waiting',
      'delayed',
      'active',
      'completed',
      'failed'
    );
    return {
      queueLength: (counts.waiting || 0) + (counts.delayed || 0),
      isProcessing: true,
      activeRequests: counts.active || 0,
      currentRate: this.currentRate,
      pausedUntil: 0,
      maxConcurrent: this.maxConcurrent
    };
  }

  async getDetailedStatus() {
    const counts = await this.queue.getJobCounts(
      'waiting',
      'delayed',
      'active',
      'completed',
      'failed'
    );
    return {
      ...counts,
      maxConcurrent: this.maxConcurrent,
      currentRate: this.currentRate,
      rateLimitWindow: this.rateLimitWindow,
      requestsInWindow: 'redis-tracked',
      isPaused: await this.worker.isPaused(),
      shouldStop: false
    };
  }

  async waitForDrain(timeoutMs = 5000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const counts = await this.queue.getJobCounts('waiting', 'delayed', 'active');
      if ((counts.waiting || 0) + (counts.delayed || 0) + (counts.active || 0) === 0) return;
      await new Promise((r) => setTimeout(r, 50));
    }
    throw new Error('Timeout while draining queue');
  }
}

// --------------------------- In-memory fallback (your current behavior) ---------------------------
class MemoryTelegramQueue extends EventEmitter {
  constructor({
    initialRate = 25,
    minRate = 3,
    maxRate = 28,
    maxConcurrent = 20,
    rateLimitWindow = 1000
  } = {}) {
    super();
    this.queue = [];
    this.currentRate = initialRate;
    this.minRate = minRate;
    this.maxRate = maxRate;
    this.maxConcurrent = maxConcurrent;
    this.rateLimitWindow = rateLimitWindow;

    this.pausedUntil = 0;
    this.activeRequests = 0;
    this.shouldStop = false;
    this.isProcessing = false;
    this.requestTimestamps = [];
  }

  registerContext() {} // no-op for compatibility

  setRate(rate) {
    this.currentRate = Math.max(this.minRate, Math.min(this.maxRate, rate));
  }

  clearQueue() {
    while (this.queue.length > 0) {
      const { reject } = this.queue.shift();
      reject(new Error('Queue cleared'));
    }
  }

  stop() { this.shouldStop = true; this.clearQueue(); }
  resume() { this.shouldStop = false; this.process(); }

  getStatus() {
    return {
      queueLength: this.queue.length,
      isProcessing: this.isProcessing,
      activeRequests: this.activeRequests,
      currentRate: this.currentRate,
      pausedUntil: this.pausedUntil,
      maxConcurrent: this.maxConcurrent
    };
  }

  getDetailedStatus() {
    const now = Date.now();
    const recentRequests = this.requestTimestamps.filter(
      t => now - t < this.rateLimitWindow
    ).length;

    return {
      queueLength: this.queue.length,
      isProcessing: this.isProcessing,
      activeRequests: this.activeRequests,
      maxConcurrent: this.maxConcurrent,
      currentRate: this.currentRate,
      requestsInWindow: recentRequests,
      rateLimitWindow: this.rateLimitWindow,
      pausedUntil: this.pausedUntil,
      isPaused: now < this.pausedUntil,
      shouldStop: this.shouldStop
    };
  }

  canMakeRequest() {
    const now = Date.now();
    this.requestTimestamps = this.requestTimestamps.filter(
      t => now - t < this.rateLimitWindow
    );
    return this.requestTimestamps.length < this.currentRate &&
           this.activeRequests < this.maxConcurrent &&
           now >= this.pausedUntil;
  }

  async processRequest(task) {
    const { fn, args, resolve, reject } = task;
    this.activeRequests++;
    this.requestTimestamps.push(Date.now());
    try {
      const result = await fn(...args);
      resolve(result);
      if (this.queue.length < 8) this.setRate(this.currentRate + 0.3);
    } catch (err) {
      const msg = String(err);
      const retryMatch = msg.match(/retry after (\d+)/i);
      if (retryMatch) {
        const waitMs = Number(retryMatch[1]) * 1000;
        this.pausedUntil = Date.now() + waitMs;
        this.setRate(this.currentRate * 0.7);
        if (!this.shouldStop) this.queue.unshift(task);
        else reject(new Error('Queue stopped during retry'));
      } else {
        reject(err);
      }
    } finally {
      this.activeRequests--;
    }
  }

  async process() {
    if (this.shouldStop || this.isProcessing) return;
    this.isProcessing = true;
    try {
      while (this.queue.length > 0 && !this.shouldStop) {
        const now = Date.now();
        if (now < this.pausedUntil) {
          await new Promise(r => setTimeout(r, this.pausedUntil - now));
          continue;
        }
        const promises = [];
        while (this.queue.length > 0 && this.canMakeRequest() && !this.shouldStop) {
          const task = this.queue.shift();
          promises.push(this.processRequest(task));
        }
        if (promises.length === 0) {
          await new Promise(r => setTimeout(r, 100));
          continue;
        }
        await Promise.race(promises);
        await new Promise(r => setTimeout(r, 10));
      }
    } finally {
      this.isProcessing = false;
      if (this.queue.length > 0 && !this.shouldStop) {
        setTimeout(() => this.process(), 50);
      }
    }
  }

  async enqueue(fn, args/*, chatId */) {
    return new Promise((resolve, reject) => {
      this.queue.push({ fn, args, resolve, reject, timestamp: Date.now() });
      this.process();
    });
  }

  async waitForDrain(timeoutMs = 5000) {
    const start = Date.now();
    while ((this.queue.length > 0 || this.activeRequests > 0) &&
           Date.now() - start < timeoutMs) {
      await new Promise(r => setTimeout(r, 50));
    }
  }
}

// Export: prefer Redis if configured
export class TelegramQueue extends (REDIS_URL ? RedisTelegramQueue : MemoryTelegramQueue) {}
