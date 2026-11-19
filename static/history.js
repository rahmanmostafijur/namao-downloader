/*
 * Namao download history (client side).
 *
 * The server deliberately has no "list my jobs" endpoint: job ids are capability
 * tokens. So each browser remembers the ids it created (plus enough display data
 * to render a row) and re-asks the server for the live state of unfinished ones.
 *
 * Everything read back from storage is untrusted and is validated field by field.
 * Entries are immutable snapshots: every change produces a new array.
 */
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.NamaoHistory = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  const KEY = "namao-history-v1";
  const MAX_ENTRIES = 100;
  const PERSIST_PROGRESS_EVERY_MS = 2000;
  const STATUSES = [
    "queued", "validating", "fetching_metadata", "downloading", "merging", "verifying",
    "completed", "failed", "cancelled", "interrupted",
  ];
  const TERMINAL = ["completed", "failed", "cancelled", "interrupted"];
  const PLATFORMS = ["youtube", "facebook", "tiktok", "twitter", "instagram"];

  const text = (value, max) => (typeof value === "string" ? value.slice(0, max) : "");
  const num = (value) => (typeof value === "number" && Number.isFinite(value) ? value : null);

  /** Validate one stored/incoming entry. Returns a clean copy or null. */
  function sanitizeEntry(raw) {
    if (!raw || typeof raw !== "object") return null;
    if (typeof raw.id !== "string" || !/^[A-Za-z0-9_-]{8,128}$/.test(raw.id)) return null;
    if (STATUSES.indexOf(raw.status) === -1) return null;
    const progress = raw.progress && typeof raw.progress === "object" ? raw.progress : {};
    const error = raw.error && typeof raw.error === "object" ? raw.error : null;
    const result = raw.result && typeof raw.result === "object" ? raw.result : null;
    const saved = raw.saved && typeof raw.saved === "object" ? raw.saved : null;
    const thumbnail = typeof raw.thumbnail === "string" && /^https:\/\//i.test(raw.thumbnail) ? raw.thumbnail.slice(0, 2048) : "";
    return {
      id: raw.id,
      url: text(raw.url, 2048),
      platform: PLATFORMS.indexOf(raw.platform) !== -1 ? raw.platform : "",
      title: text(raw.title, 300),
      uploader: text(raw.uploader, 200),
      thumbnail,
      durationSeconds: num(raw.durationSeconds),
      quality: text(raw.quality, 16),
      qualityLabel: text(raw.qualityLabel, 64),
      createdAt: num(raw.createdAt) || 0,
      status: raw.status,
      attempt: num(raw.attempt) || 0,
      maxAttempts: num(raw.maxAttempts) || 1,
      progress: {
        percent: num(progress.percent) || 0,
        downloaded_bytes: num(progress.downloaded_bytes),
        total_bytes: num(progress.total_bytes),
        speed_bps: num(progress.speed_bps),
        eta_seconds: num(progress.eta_seconds),
      },
      error: error
        ? { code: text(error.code, 64), message: text(error.message, 500), retryable: error.retryable !== false }
        : null,
      result: result
        ? {
            filename: text(result.filename, 300),
            size_bytes: num(result.size_bytes) || 0,
            height: num(result.height),
            duration_seconds: num(result.duration_seconds),
          }
        : null,
      expiresAt: num(raw.expiresAt),
      saved: saved ? { name: text(saved.name, 300) } : null,
    };
  }

  /** Merge a server job record (and optional display metadata) into an entry. */
  function fromJob(job, meta, previous) {
    const base = previous || {};
    const m = meta || {};
    const error = job.error || null;
    const result = job.result || null;
    return sanitizeEntry({
      id: job.id || base.id,
      url: m.url !== undefined ? m.url : base.url,
      platform: job.platform || m.platform || base.platform,
      title: job.title || m.title || base.title,
      uploader: m.uploader !== undefined ? m.uploader : base.uploader,
      thumbnail: m.thumbnail !== undefined ? m.thumbnail : base.thumbnail,
      durationSeconds: m.durationSeconds !== undefined ? m.durationSeconds : base.durationSeconds,
      quality: job.quality || m.quality || base.quality,
      qualityLabel: m.qualityLabel !== undefined ? m.qualityLabel : base.qualityLabel,
      createdAt: base.createdAt || m.createdAt || (job.created_at ? Date.parse(job.created_at) : Date.now()),
      status: job.status,
      attempt: job.attempt,
      maxAttempts: job.max_attempts,
      progress: job.progress,
      error,
      result,
      expiresAt: job.expires_at ? Date.parse(job.expires_at) : base.expiresAt,
      saved: base.saved,
    });
  }

  const isTerminal = (entry) => TERMINAL.indexOf(entry.status) !== -1;

  /** A completed job whose server-side file has passed its retention time. */
  function isExpired(entry, now) {
    return entry.status === "completed" && entry.expiresAt !== null && entry.expiresAt <= (now === undefined ? Date.now() : now);
  }

  /** Which tab an entry belongs to. Cancelled and interrupted jobs live under "failed". */
  function bucket(entry) {
    if (entry.status === "completed") return "completed";
    return isTerminal(entry) ? "failed" : "active";
  }

  function counts(entries) {
    return entries.reduce(
      (acc, entry) => ({ ...acc, [bucket(entry)]: acc[bucket(entry)] + 1 }),
      { active: 0, completed: 0, failed: 0 }
    );
  }

  function parse(rawJson) {
    let data;
    try {
      data = JSON.parse(rawJson);
    } catch (e) {
      return [];
    }
    if (!Array.isArray(data)) return [];
    const seen = new Set();
    return data
      .map(sanitizeEntry)
      .filter((entry) => entry && !seen.has(entry.id) && seen.add(entry.id))
      .sort((a, b) => b.createdAt - a.createdAt)
      .slice(0, MAX_ENTRIES);
  }

  /**
   * A small observable store. `storage` is anything with getItem/setItem (or null).
   * Storage failures (private mode, quota) never break the app: history just becomes in-memory.
   */
  function createStore(storage, clock) {
    const now = clock || Date.now;
    let entries = [];
    let lastPersist = 0;
    const listeners = new Set();

    try {
      entries = storage ? parse(storage.getItem(KEY)) : [];
    } catch (e) {
      entries = [];
    }

    function persist(force) {
      const t = now();
      if (!force && t - lastPersist < PERSIST_PROGRESS_EVERY_MS) return;
      lastPersist = t;
      try {
        if (storage) storage.setItem(KEY, JSON.stringify(entries));
      } catch (e) {
        /* storage full or blocked: keep working in memory */
      }
    }

    function commit(next, force, skipPersist) {
      entries = next.sort((a, b) => b.createdAt - a.createdAt).slice(0, MAX_ENTRIES);
      if (!skipPersist) persist(force);
      listeners.forEach((fn) => fn(entries));
    }

    return {
      list: () => entries,
      get: (id) => entries.find((entry) => entry.id === id) || null,
      /** Add or replace an entry. Status changes persist immediately; pure progress ticks are throttled. */
      put(entry) {
        const clean = sanitizeEntry(entry);
        if (!clean) return null;
        const previous = entries.find((e) => e.id === clean.id);
        const savedName = (entry) => (entry && entry.saved ? entry.saved.name : null);
        const force = !previous || previous.status !== clean.status || savedName(previous) !== savedName(clean);
        commit([clean, ...entries.filter((e) => e.id !== clean.id)], force);
        return clean;
      },
      /** Merge a fresh server job record into the stored entry (no-op for unknown ids unless `meta` is given). */
      applyJob(job, meta) {
        const previous = entries.find((e) => e.id === job.id);
        if (!previous && !meta) return null;
        const next = fromJob(job, meta, previous);
        return next ? this.put(next) : null;
      },
      markSaved(id, name) {
        const previous = entries.find((e) => e.id === id);
        return previous ? this.put({ ...previous, saved: { name } }) : null;
      },
      remove(id) {
        commit(entries.filter((e) => e.id !== id), true);
      },
      removeWhere(predicate) {
        commit(entries.filter((e) => !predicate(e)), true);
      },
      clear() {
        commit([], true);
      },
      /**
       * Adopt the list another tab just wrote (a `storage` event). Membership follows the other tab, so
       * deletions propagate and jobs it started appear here. Where this tab already knows more (a job it
       * saw finish, or a file it saved), that knowledge is kept. Nothing is written back (no echo loop).
       */
      adopt(rawJson) {
        const mine = new Map(entries.map((e) => [e.id, e]));
        commit(
          parse(rawJson).map((theirs) => {
            const local = mine.get(theirs.id);
            if (!local) return theirs;
            const base = isTerminal(local) && !isTerminal(theirs) ? local : theirs;
            return !base.saved && local.saved ? { ...base, saved: local.saved } : base;
          }),
          false,
          true
        );
      },
      subscribe(fn) {
        listeners.add(fn);
        return () => listeners.delete(fn);
      },
    };
  }

  return { KEY, MAX_ENTRIES, STATUSES, createStore, sanitizeEntry, fromJob, bucket, counts, isExpired, isTerminal, parse };
});
