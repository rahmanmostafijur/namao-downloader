"use strict";
// Run with: node --test tests/web
const test = require("node:test");
const assert = require("node:assert/strict");

const History = require("../../static/history.js");

const T0 = 1760000000000;

function memoryStorage(initial) {
  const data = new Map(initial ? [[History.KEY, initial]] : []);
  return {
    data,
    getItem: (k) => (data.has(k) ? data.get(k) : null),
    setItem: (k, v) => data.set(k, v),
  };
}

function entry(overrides) {
  return { id: "job00000001", status: "queued", createdAt: T0, quality: "1080", ...overrides };
}

function job(overrides) {
  return { id: "job00000001", status: "downloading", platform: "youtube", quality: "1080", attempt: 0, max_attempts: 3, progress: { percent: 10 }, ...overrides };
}

test("sanitizeEntry rejects malformed ids and unknown statuses", () => {
  assert.equal(History.sanitizeEntry(null), null);
  assert.equal(History.sanitizeEntry({ id: "../../etc", status: "queued" }), null);
  assert.equal(History.sanitizeEntry({ id: "short", status: "queued" }), null);
  assert.equal(History.sanitizeEntry({ id: "job00000001", status: "teleporting" }), null);
  assert.equal(History.sanitizeEntry(entry()).id, "job00000001");
});

test("sanitizeEntry never trusts stored text: caps lengths, drops non-https thumbnails, coerces numbers", () => {
  const clean = History.sanitizeEntry(
    entry({
      title: "x".repeat(5000),
      thumbnail: "javascript:alert(1)",
      progress: { percent: "50", speed_bps: NaN, downloaded_bytes: 12 },
      error: { code: 7, message: "m".repeat(2000), retryable: false },
    })
  );
  assert.equal(clean.title.length, 300);
  assert.equal(clean.thumbnail, "");
  assert.equal(clean.progress.percent, 0, "a numeric string is not a number");
  assert.equal(clean.progress.speed_bps, null);
  assert.equal(clean.progress.downloaded_bytes, 12);
  assert.equal(clean.error.code, "");
  assert.equal(clean.error.message.length, 500);
  assert.equal(clean.error.retryable, false);
  assert.equal(History.sanitizeEntry(entry({ thumbnail: "https://i.ytimg.com/a.jpg" })).thumbnail, "https://i.ytimg.com/a.jpg");
});

test("parse tolerates corrupt storage and drops duplicates", () => {
  assert.deepEqual(History.parse("not json"), []);
  assert.deepEqual(History.parse('{"a":1}'), []);
  assert.deepEqual(History.parse(null), []);
  const parsed = History.parse(JSON.stringify([entry(), entry({ title: "dup" }), { junk: true }, entry({ id: "job00000002", createdAt: T0 + 5 })]));
  assert.deepEqual(parsed.map((e) => e.id), ["job00000002", "job00000001"], "newest first, one per id, junk removed");
});

test("bucket puts cancelled and interrupted jobs under failed", () => {
  const bucket = (status) => History.bucket(History.sanitizeEntry(entry({ status })));
  for (const s of ["queued", "validating", "fetching_metadata", "downloading", "merging", "verifying"]) assert.equal(bucket(s), "active", s);
  assert.equal(bucket("completed"), "completed");
  for (const s of ["failed", "cancelled", "interrupted"]) assert.equal(bucket(s), "failed", s);
});

test("counts totals each bucket", () => {
  const entries = ["queued", "downloading", "completed", "failed", "cancelled"].map((status, i) =>
    History.sanitizeEntry(entry({ id: "job0000000" + i, status }))
  );
  assert.deepEqual(History.counts(entries), { active: 2, completed: 1, failed: 2 });
});

test("isExpired only applies to completed jobs past their retention time", () => {
  const done = History.sanitizeEntry(entry({ status: "completed", expiresAt: T0 + 1000 }));
  assert.equal(History.isExpired(done, T0 + 999), false);
  assert.equal(History.isExpired(done, T0 + 1000), true);
  assert.equal(History.isExpired(History.sanitizeEntry(entry({ status: "completed" })), T0 + 1e9), false, "no expiry known");
  assert.equal(History.isExpired(History.sanitizeEntry(entry({ status: "failed", expiresAt: T0 })), T0 + 5), false);
});

test("applyJob merges real server state into a stored entry and keeps display metadata", () => {
  const store = History.createStore(null, () => T0);
  store.applyJob(job({ title: null }), { url: "https://youtu.be/x", title: "From metadata", thumbnail: "https://i.ytimg.com/a.jpg", qualityLabel: "1080p", createdAt: T0 });
  store.applyJob(job({ status: "downloading", progress: { percent: 42, speed_bps: 1000, eta_seconds: 9 } }));
  const e = store.get("job00000001");
  assert.equal(e.status, "downloading");
  assert.equal(e.progress.percent, 42);
  assert.equal(e.title, "From metadata", "metadata survives later updates");
  assert.equal(e.url, "https://youtu.be/x");
  assert.equal(e.qualityLabel, "1080p");
  store.applyJob(job({ status: "completed", progress: { percent: 100 }, result: { filename: "a.mp4", size_bytes: 10, height: 1080 }, expires_at: "2026-10-20T10:00:00Z" }));
  const done = store.get("job00000001");
  assert.equal(done.result.filename, "a.mp4");
  assert.equal(done.expiresAt, Date.parse("2026-10-20T10:00:00Z"));
});

test("applyJob ignores jobs this browser never created (no metadata, unknown id)", () => {
  const store = History.createStore(null);
  assert.equal(store.applyJob(job({ id: "someoneelses1" })), null);
  assert.equal(store.list().length, 0);
});

test("status changes persist immediately; progress ticks are throttled", () => {
  let now = T0;
  const storage = memoryStorage();
  const store = History.createStore(storage, () => now);
  store.applyJob(job({ progress: { percent: 1 } }), { createdAt: T0 });
  const first = storage.data.get(History.KEY);
  now += 500;
  store.applyJob(job({ progress: { percent: 2 } }));
  assert.equal(storage.data.get(History.KEY), first, "progress-only change inside the window is not written");
  now += 2000;
  store.applyJob(job({ progress: { percent: 3 } }));
  assert.notEqual(storage.data.get(History.KEY), first, "written once the window has passed");
  store.applyJob(job({ status: "completed", progress: { percent: 100 }, result: { filename: "a.mp4", size_bytes: 1 } }));
  assert.equal(JSON.parse(storage.data.get(History.KEY))[0].status, "completed", "status change is written immediately");
});

test("a new store restores what the previous one saved", () => {
  const storage = memoryStorage();
  const a = History.createStore(storage);
  a.applyJob(job({ status: "completed", progress: { percent: 100 }, result: { filename: "a.mp4", size_bytes: 1 } }), { title: "Saved", createdAt: T0 });
  const b = History.createStore(storage);
  assert.equal(b.list().length, 1);
  assert.equal(b.get("job00000001").title, "Saved");
});

test("remove, removeWhere and clear update subscribers and storage", () => {
  const storage = memoryStorage();
  const store = History.createStore(storage);
  const seen = [];
  store.subscribe((list) => seen.push(list.length));
  store.put(entry({ id: "job00000001" }));
  store.put(entry({ id: "job00000002", status: "failed", createdAt: T0 + 1 }));
  store.put(entry({ id: "job00000003", status: "failed", createdAt: T0 + 2 }));
  store.removeWhere((e) => e.status === "failed");
  assert.deepEqual(store.list().map((e) => e.id), ["job00000001"]);
  store.remove("job00000001");
  assert.equal(store.list().length, 0);
  store.put(entry());
  store.clear();
  assert.equal(JSON.parse(storage.data.get(History.KEY)).length, 0);
  assert.deepEqual(seen.slice(0, 3), [1, 2, 3]);
});

test("markSaved records the desktop file name and is a no-op for unknown ids", () => {
  const store = History.createStore(null);
  store.put(entry({ status: "completed" }));
  assert.equal(store.markSaved("job00000001", "My Video.mp4").saved.name, "My Video.mp4");
  assert.equal(store.markSaved("nope00000000", "x"), null);
});

test("history is capped and unsubscribing stops notifications", () => {
  const store = History.createStore(null);
  let calls = 0;
  const off = store.subscribe(() => calls++);
  for (let i = 0; i < History.MAX_ENTRIES + 20; i++) store.put(entry({ id: "job" + String(i).padStart(8, "0"), createdAt: T0 + i }));
  assert.equal(store.list().length, History.MAX_ENTRIES);
  assert.equal(store.list()[0].id, "job" + String(History.MAX_ENTRIES + 19).padStart(8, "0"), "newest kept");
  off();
  const before = calls;
  store.put(entry({ id: "job99999999", createdAt: T0 + 9999 }));
  assert.equal(calls, before);
});

test("adopt follows another tab: new jobs appear, deletions propagate, nothing is written back", () => {
  const storage = memoryStorage();
  const store = History.createStore(storage);
  store.put(entry({ id: "job00000001" }));
  store.put(entry({ id: "job00000002", createdAt: T0 + 1 }));
  const written = storage.data.get(History.KEY);
  // the other tab removed job 1 and started job 3
  const theirs = JSON.stringify([entry({ id: "job00000002", createdAt: T0 + 1 }), entry({ id: "job00000003", createdAt: T0 + 2 })]);
  let notified = 0;
  store.subscribe(() => notified++);
  store.adopt(theirs);
  assert.deepEqual(store.list().map((e) => e.id), ["job00000003", "job00000002"]);
  assert.equal(notified, 1);
  assert.equal(storage.data.get(History.KEY), written, "adopting must not echo a write back to storage");
});

test("adopt keeps what this tab already knows: a finished job stays finished and a saved file stays saved", () => {
  const store = History.createStore(null);
  store.put(entry({ id: "job00000001", status: "completed", saved: { name: "a.mp4" }, result: { filename: "a.mp4", size_bytes: 1 } }));
  store.adopt(JSON.stringify([entry({ id: "job00000001", status: "downloading" })]));
  assert.equal(store.get("job00000001").status, "completed", "a stale non-terminal snapshot must not reopen a finished job");
  store.adopt(JSON.stringify([entry({ id: "job00000001", status: "completed", result: { filename: "a.mp4", size_bytes: 1 } })]));
  assert.equal(store.get("job00000001").saved.name, "a.mp4", "saved marker survives an update that lacks it");
  store.adopt("garbage");
  assert.equal(store.list().length, 0, "unreadable data from another tab is treated as an empty list, never a crash");
});

test("only the five known platforms are accepted, so odd keys can never reach a label lookup", () => {
  for (const bad of ["__proto__", "constructor", "toString", "myspace", 5]) {
    assert.equal(History.sanitizeEntry(entry({ platform: bad })).platform, "", String(bad));
  }
  assert.equal(History.sanitizeEntry(entry({ platform: "tiktok" })).platform, "tiktok");
});

test("storage that throws never breaks the store", () => {
  const broken = {
    getItem() {
      throw new Error("blocked");
    },
    setItem() {
      throw new Error("quota");
    },
  };
  const store = History.createStore(broken);
  assert.equal(store.list().length, 0);
  assert.doesNotThrow(() => store.put(entry()));
  assert.equal(store.list().length, 1, "still works in memory");
});
