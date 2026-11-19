"use strict";
// Run with: node --test tests/web
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const App = require("../../static/app.js");
const History = require("../../static/history.js");
const UI = require("../../static/components.js");

const NOW = 1760000000000;
const STATIC = path.join(__dirname, "..", "..", "static");

function entry(overrides) {
  return History.sanitizeEntry({ id: "job00000001", status: "queued", createdAt: NOW, url: "https://youtu.be/x", ...overrides });
}
const actions = (e, desktop) => UI.actionsFor(e, UI.describeEntry(e, NOW), !!desktop);

test("active jobs can only be cancelled", () => {
  for (const status of ["queued", "validating", "fetching_metadata", "downloading", "merging", "verifying"]) {
    assert.deepEqual(actions(entry({ status })), ["cancel"], status);
  }
});

test("a cancelled or interrupted job can always be retried, even if the server marked it non-retryable", () => {
  const error = { code: "cancelled", message: "The download was cancelled.", retryable: false };
  assert.deepEqual(actions(entry({ status: "cancelled", error })), ["retry", "remove"]);
  assert.deepEqual(actions(entry({ status: "interrupted", error })), ["retry", "remove"]);
});

test("a failed job is retryable only when the server says it may succeed", () => {
  assert.deepEqual(actions(entry({ status: "failed", error: { code: "network_transient", message: "x", retryable: true } })), ["retry", "remove"]);
  assert.deepEqual(actions(entry({ status: "failed", error: { code: "video_unavailable", message: "x", retryable: false } })), ["remove"]);
});

test("retry needs a source URL (older or imported entries without one can only be removed)", () => {
  assert.deepEqual(actions(entry({ status: "failed", url: "", error: { code: "x", message: "x", retryable: true } })), ["remove"]);
});

test("completed jobs offer save; expired ones offer 'download again' instead of a dead link", () => {
  const fresh = entry({ status: "completed", result: { filename: "a.mp4", size_bytes: 5 }, expiresAt: NOW + 60000 });
  assert.deepEqual(actions(fresh), ["save", "remove"]);
  const expired = entry({ status: "completed", result: { filename: "a.mp4", size_bytes: 5 }, expiresAt: NOW - 1 });
  assert.deepEqual(actions(expired), ["again", "remove"]);
  assert.equal(UI.describeEntry(expired, NOW).headline, "Expired");
  assert.match(UI.describeEntry(expired, NOW).message, /removed this file/);
});

test("desktop mode offers save-to-folder until the job has been saved", () => {
  const done = entry({ status: "completed", result: { filename: "a.mp4", size_bytes: 5 } });
  assert.deepEqual(actions(done, true), ["save-folder", "save", "remove"]);
  assert.deepEqual(actions({ ...done, saved: { name: "a.mp4" } }, true), ["open-folder", "save", "remove"]);
  assert.equal(UI.describeEntry({ ...done, saved: { name: "a.mp4" } }, NOW).headline, "Saved");
});

test("describeEntry reports real progress details and never invents any", () => {
  const info = UI.describeEntry(
    entry({ status: "downloading", progress: { percent: 40.2, downloaded_bytes: 4 * 1024 * 1024, total_bytes: 10 * 1024 * 1024, speed_bps: 1048576, eta_seconds: 6 } }),
    NOW
  );
  assert.equal(info.headline, "Downloading 40%");
  assert.equal(info.detail, "4.0 MB of 10.0 MB · 1.0 MB/s · 6s left");
  assert.equal(info.view.indeterminate, false);
  const merging = UI.describeEntry(entry({ status: "merging", progress: { percent: 99 } }), NOW);
  assert.equal(merging.view.indeterminate, true, "merging is never shown as a percentage");
  assert.equal(merging.detail, "");
});

test("failed states show the status word and the server's message separately, in the danger tone", () => {
  const info = UI.describeEntry(entry({ status: "failed", error: { code: "access_blocked", message: "The platform is blocking this server.", retryable: false } }), NOW);
  assert.equal(info.headline, "Failed");
  assert.equal(info.message, "The platform is blocking this server.");
  assert.equal(info.tone, "danger");
  assert.equal(UI.describeEntry(entry({ status: "completed", result: { filename: "a", size_bytes: 1 } }), NOW).tone, "success");
});

test("formatAgo", () => {
  assert.equal(App.formatAgo(NOW, NOW + 10_000), "just now");
  assert.equal(App.formatAgo(NOW, NOW + 5 * 60_000), "5 min ago");
  assert.equal(App.formatAgo(NOW, NOW + 3 * 3600_000), "3 h ago");
  assert.equal(App.formatAgo(NOW, NOW + 2 * 86400_000), "2 d ago");
  assert.equal(App.formatAgo(NOW, NOW - 5000), "just now", "clock skew never yields a negative age");
  assert.equal(App.formatAgo(NaN, NOW), "");
});

test("sizeLabel marks estimates and never guesses a missing size", () => {
  assert.equal(App.sizeLabel({ size_bytes: 210 * 1024 * 1024, size_estimated: true }), "~210.0 MB");
  assert.equal(App.sizeLabel({ size_bytes: 1536, size_estimated: false }), "1.5 KB");
  assert.equal(App.sizeLabel({ size_bytes: null, size_estimated: false }), "size unknown");
  assert.equal(App.sizeLabel(undefined), "size unknown");
});

test("health() returns the body for a degraded (503) report instead of throwing", async () => {
  const api = App.createApi(() => Promise.resolve({ ok: false, status: 503, json: () => Promise.resolve({ status: "degraded", checks: { ffmpeg: { ok: false } } }) }));
  const report = await api.health();
  assert.equal(report.httpStatus, 503);
  assert.equal(report.body.status, "degraded");
  const sent = [];
  await App.createApi((url, options) => { sent.push([url, options.headers["X-API-Key"]]); return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({}) }); }, { apiKey: "k" }).health();
  assert.deepEqual(sent, [["/health/ready", "k"]]);
});

test("the poller reports the HTTP status when it gives up, so a 404 is distinguishable from a network outage", async () => {
  const api = App.createApi(() => Promise.resolve({ ok: false, status: 404, json: () => Promise.resolve({ error: { code: "not_found", message: "Not found.", retryable: false } }) }));
  const seen = [];
  api.watch("gone", (job) => seen.push(job), { EventSource: null, setTimeout: () => 1, clearTimeout() {} });
  await new Promise((r) => setImmediate(r));
  assert.equal(seen[0].error.code, "client_error");
  assert.equal(seen[0].error.http_status, 404);
});

test("no client script injects markup, and the page keeps its CSP-friendly script structure", () => {
  const scripts = fs.readdirSync(STATIC).filter((f) => f.endsWith(".js"));
  assert.ok(scripts.length >= 6, "expected app, history, dom, components, main, theme-init");
  for (const file of scripts) {
    const source = fs.readFileSync(path.join(STATIC, file), "utf8");
    assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(|new Function/.test(source), file + " must not inject HTML or evaluate strings");
  }
  const html = fs.readFileSync(path.join(STATIC, "index.html"), "utf8");
  assert.ok(!/<script>/.test(html) && !/\son[a-z]+=/.test(html), "no inline scripts or inline event handlers");
  for (const file of ["theme-init.js", "app.js", "history.js", "dom.js", "components.js", "main.js"]) {
    assert.ok(html.includes('<script src="' + file + '"></script>'), file + " is loaded");
  }
  assert.ok(html.indexOf("app.js") < html.indexOf("history.js") && html.indexOf("dom.js") < html.indexOf("components.js") && html.indexOf("components.js") < html.indexOf("main.js"), "dependency order");
});

test("every element id main.js looks up exists in index.html", () => {
  const html = fs.readFileSync(path.join(STATIC, "index.html"), "utf8");
  const main = fs.readFileSync(path.join(STATIC, "main.js"), "utf8");
  const ids = new Set(Array.from(html.matchAll(/\sid="([^"]+)"/g), (m) => m[1]));
  const looked = Array.from(main.matchAll(/\$\("([^"]+)"\)/g), (m) => m[1]);
  assert.ok(looked.length > 40);
  const missing = looked.filter((id) => !ids.has(id));
  assert.deepEqual(missing, []);
});
