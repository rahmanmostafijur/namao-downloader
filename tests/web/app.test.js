"use strict";
// Run with: node --test tests/web
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const app = require("../../static/app.js");

const jsonResponse = (status, body) => ({
  ok: status >= 200 && status < 300,
  status,
  json: () => Promise.resolve(body),
});

test("detectPlatform accepts real platform hosts and rejects look-alikes", () => {
  assert.equal(app.detectPlatform("https://www.youtube.com/watch?v=abc"), "youtube");
  assert.equal(app.detectPlatform("youtu.be/abc"), "youtube");
  assert.equal(app.detectPlatform("https://vm.tiktok.com/ZM1/"), "tiktok");
  assert.equal(app.detectPlatform("https://fb.watch/x/"), "facebook");
  assert.equal(app.detectPlatform("https://x.com/u/status/1"), "twitter");
  assert.equal(app.detectPlatform("https://www.instagram.com/reel/x/"), "instagram");
  for (const bad of [
    "https://evil.example/?u=youtube.com",
    "https://youtube.com.evil.example/",
    "https://notyoutube.com/",
    "",
    "not a url",
    null,
  ]) {
    assert.equal(app.detectPlatform(bad), null, String(bad));
  }
});

test("formatters", () => {
  assert.equal(app.formatBytes(0), "0 B");
  assert.equal(app.formatBytes(1536), "1.5 KB");
  assert.equal(app.formatBytes(5 * 1024 ** 3), "5.0 GB");
  assert.equal(app.formatBytes(null), null);
  assert.equal(app.formatBytes(-1), null);
  assert.equal(app.formatDuration(59), "0:59");
  assert.equal(app.formatDuration(3661), "1:01:01");
  assert.equal(app.formatEta(90), "1m 30s left");
  assert.equal(app.formatEta(null), "");
});

test("describeJob shows real server state and never invents progress", () => {
  const downloading = app.describeJob({
    status: "downloading",
    progress: { percent: 42.4, speed_bps: 2097152, eta_seconds: 30 },
  });
  assert.equal(downloading.label, "Downloading 42%");
  assert.equal(downloading.percent, 42.4);
  assert.equal(downloading.detail, "2.0 MB/s · 30s left");
  assert.equal(downloading.indeterminate, false);
  assert.equal(downloading.canCancel, true);

  for (const status of ["queued", "validating", "fetching_metadata", "merging", "verifying"]) {
    const view = app.describeJob({ status, progress: { percent: 0 } });
    assert.equal(view.indeterminate, true, status);
    assert.equal(view.canCancel, true, status);
  }

  const retrying = app.describeJob({ status: "queued", attempt: 1, max_attempts: 3, progress: {} });
  assert.match(retrying.label, /Retrying \(attempt 2 of 3\)/);
});

test("describeJob: failures surface the server's normalized message and are never 'success'", () => {
  const failed = app.describeJob({
    status: "failed",
    progress: { percent: 80 },
    error: { code: "geo_restricted", message: "This video isn't available in the server's region.", retryable: false },
  });
  assert.equal(failed.label, "This video isn't available in the server's region.");
  assert.equal(failed.terminal, true);
  assert.equal(failed.canCancel, false);
  assert.notEqual(failed.status, "completed");
  assert.equal(app.describeJob({ status: "completed", progress: { percent: 100 } }).label, "Ready");
});

test("API client sends the error envelope fields, idempotency key and API key", async () => {
  const calls = [];
  const api = app.createApi(
    (url, options) => {
      calls.push({ url, options });
      return Promise.resolve(jsonResponse(202, { id: "abc", status: "queued" }));
    },
    { apiKey: "k" }
  );
  await api.create("https://youtu.be/x", "1080", "idem-12345678");
  assert.equal(calls[0].url, "/api/v1/downloads");
  assert.equal(calls[0].options.method, "POST");
  assert.deepEqual(JSON.parse(calls[0].options.body), { url: "https://youtu.be/x", quality: "1080" });
  assert.equal(calls[0].options.headers["Idempotency-Key"], "idem-12345678");
  assert.equal(calls[0].options.headers["X-API-Key"], "k");
  assert.equal(api.fileUrl("a/b"), "/api/v1/downloads/a%2Fb/file");
});

test("API client turns the error envelope into an Error with code and retryable", async () => {
  const api = app.createApi(() =>
    Promise.resolve(
      jsonResponse(422, { error: { code: "video_unavailable", message: "This video is unavailable.", retryable: false } })
    )
  );
  await assert.rejects(api.metadata("https://youtu.be/x"), (err) => {
    assert.equal(err.message, "This video is unavailable.");
    assert.equal(err.status, 422);
    assert.equal(err.code, "video_unavailable");
    assert.equal(err.retryable, false);
    return true;
  });
});

test("API client copes with a non-JSON error body", async () => {
  const api = app.createApi(() => Promise.resolve({ ok: false, status: 502, json: () => Promise.reject(new Error("x")) }));
  await assert.rejects(api.get("abc"), /Request failed \(502\)/);
});

function fakeTimers() {
  const queue = [];
  return {
    queue,
    setTimeout: (fn) => {
      queue.push(fn);
      return queue.length;
    },
    clearTimeout: () => {},
    runNext: async () => {
      const fn = queue.shift();
      if (fn) await fn();
      await new Promise((r) => setImmediate(r));
    },
  };
}

test("watch (polling) reports every state and stops after the terminal one", async () => {
  const states = [{ status: "queued" }, { status: "downloading", progress: { percent: 10 } }, { status: "completed" }];
  let calls = 0;
  const api = app.createApi(() => Promise.resolve(jsonResponse(200, states[Math.min(calls++, 2)])));
  const timers = fakeTimers();
  const seen = [];
  api.watch("id1", (job) => seen.push(job.status), { EventSource: null, ...timers });
  await new Promise((r) => setImmediate(r));
  await timers.runNext();
  await timers.runNext();
  assert.deepEqual(seen, ["queued", "downloading", "completed"]);
  assert.equal(timers.queue.length, 0, "no further polling once terminal");
  assert.equal(calls, 3);
});

test("watch (polling) treats 404 as final and retries transient network errors", async () => {
  let n = 0;
  const api = app.createApi(() => {
    n++;
    if (n === 1) return Promise.reject(new Error("network down"));
    return Promise.resolve(jsonResponse(404, { error: { code: "not_found", message: "Not found.", retryable: false } }));
  });
  const timers = fakeTimers();
  const seen = [];
  api.watch("gone", (job) => seen.push(job), { EventSource: null, ...timers });
  await new Promise((r) => setImmediate(r));
  assert.equal(seen.length, 0, "transient error is retried, not surfaced");
  await timers.runNext();
  assert.equal(seen.length, 1);
  assert.equal(seen[0].status, "failed");
  assert.equal(seen[0].error.message, "Not found.");
});

test("watch (SSE) forwards job events and closes on the terminal one", async () => {
  const listeners = {};
  let closed = false;
  class FakeEventSource {
    constructor(url) {
      this.url = url;
      FakeEventSource.last = this;
    }
    addEventListener(name, fn) {
      listeners[name] = fn;
    }
    close() {
      closed = true;
    }
  }
  const api = app.createApi(() => Promise.reject(new Error("fetch must not be used for SSE")));
  const seen = [];
  api.watch("job1", (job) => seen.push(job.status), { EventSource: FakeEventSource });
  assert.equal(FakeEventSource.last.url, "/api/v1/downloads/job1/progress");
  listeners.job({ data: JSON.stringify({ status: "downloading", progress: { percent: 5 } }) });
  listeners.job({ data: "not json" });
  listeners.job({ data: JSON.stringify({ status: "completed" }) });
  assert.deepEqual(seen, ["downloading", "completed"]);
  assert.equal(closed, true);
});

test("watch falls back to polling when the SSE connection fails", async () => {
  class BrokenEventSource {
    constructor() {
      BrokenEventSource.last = this;
    }
    addEventListener() {}
    close() {}
  }
  let polled = 0;
  const api = app.createApi(() => {
    polled++;
    return Promise.resolve(jsonResponse(200, { status: "completed" }));
  });
  const seen = [];
  api.watch("job2", (job) => seen.push(job.status), { EventSource: BrokenEventSource, ...fakeTimers() });
  BrokenEventSource.last.onerror();
  await new Promise((r) => setImmediate(r));
  assert.equal(polled, 1);
  assert.deepEqual(seen, ["completed"]);
});

test("an API key forces polling (EventSource cannot send headers)", async () => {
  let constructed = false;
  class Spy {
    constructor() {
      constructed = true;
    }
  }
  const api = app.createApi(() => Promise.resolve(jsonResponse(200, { status: "completed" })), { apiKey: "k" });
  api.watch("j", () => {}, { EventSource: Spy, ...fakeTimers() });
  await new Promise((r) => setImmediate(r));
  assert.equal(constructed, false);
});

test("stop() prevents further callbacks", async () => {
  const api = app.createApi(() => Promise.resolve(jsonResponse(200, { status: "downloading", progress: {} })));
  const timers = fakeTimers();
  const seen = [];
  const stop = api.watch("j", (job) => seen.push(job.status), { EventSource: null, ...timers });
  stop();
  await new Promise((r) => setImmediate(r));
  await timers.runNext();
  assert.deepEqual(seen, []);
});

test("client never injects server data as HTML", () => {
  const source = fs.readFileSync(path.join(__dirname, "..", "..", "static", "app.js"), "utf8");
  assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(/.test(source));
  const html = fs.readFileSync(path.join(__dirname, "..", "..", "static", "index.html"), "utf8");
  assert.ok(!/NamaoBridge/.test(html), "dead Android WebView bridge removed");
  assert.ok(/<script src="app.js">/.test(html), "script is external so CSP can forbid inline scripts");
  assert.ok(!/<script>/.test(html));
});

test("desktop client methods send the custom header and only the documented bodies", async () => {
  const calls = [];
  const api = app.createApi((url, options) => {
    calls.push({ url, options });
    return Promise.resolve(jsonResponse(200, { output_dir: "/home/u/Namao", auto_save: true, name: "a.mp4" }));
  });
  await api.desktopPrefs();
  await api.desktopSetPrefs("/home/u/Videos", false);
  await api.desktopSave("job/1");
  await api.desktopOpenFolder();
  assert.deepEqual(
    calls.map((c) => [c.options.method, c.url]),
    [
      ["GET", "/api/v1/desktop/preferences"],
      ["PUT", "/api/v1/desktop/preferences"],
      ["POST", "/api/v1/desktop/jobs/job%2F1/save"],
      ["POST", "/api/v1/desktop/open-folder"],
    ]
  );
  for (const call of calls) assert.equal(call.options.headers["X-Namao-Desktop"], "1");
  assert.deepEqual(JSON.parse(calls[1].options.body), { output_dir: "/home/u/Videos", auto_save: false });
  assert.equal(calls[3].options.body, undefined, "open-folder takes no client-supplied path");
});

test("the normal download calls do not carry the desktop header", async () => {
  let headers;
  const api = app.createApi((url, options) => {
    headers = options.headers;
    return Promise.resolve(jsonResponse(200, {}));
  });
  await api.get("abc");
  assert.equal(headers["X-Namao-Desktop"], undefined);
});
