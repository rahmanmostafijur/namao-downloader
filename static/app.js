/*
 * Namao web client. Talks to the v1 download-job API only; every number and
 * state it shows comes from the server's job record (no simulated progress).
 *
 * The file works both in the browser (window.NamaoApp) and under Node
 * (require("./app.js")) so the logic can be unit-tested with `node --test`.
 * All server-provided text is inserted as text nodes, never parsed as HTML.
 */
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.NamaoApp = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var TERMINAL = ["completed", "failed", "cancelled", "interrupted"];
  var DESKTOP_HEADER = { "X-Namao-Desktop": "1" };
  var STATUS_LABELS = {
    queued: "Waiting in queue…",
    validating: "Checking link…",
    fetching_metadata: "Reading video info…",
    downloading: "Downloading",
    merging: "Merging audio and video…",
    verifying: "Verifying file…",
    completed: "Ready",
    failed: "Failed",
    cancelled: "Cancelled",
    interrupted: "Interrupted",
  };

  // UI hint only (instant platform colour); the server is the authority.
  var PLATFORM_HOSTS = {
    youtube: ["youtube.com", "youtu.be", "youtube-nocookie.com"],
    facebook: ["facebook.com", "fb.watch", "fb.com"],
    tiktok: ["tiktok.com"],
    twitter: ["twitter.com", "x.com"],
    instagram: ["instagram.com"],
  };

  function hostOf(value) {
    var text = String(value || "").trim();
    if (!text) return "";
    if (text.indexOf("://") === -1) text = "https://" + text;
    try {
      return new URL(text).hostname.toLowerCase().replace(/\.$/, "");
    } catch (e) {
      return "";
    }
  }

  function detectPlatform(value) {
    var host = hostOf(value);
    if (!host) return null;
    var names = Object.keys(PLATFORM_HOSTS);
    for (var i = 0; i < names.length; i++) {
      var domains = PLATFORM_HOSTS[names[i]];
      for (var j = 0; j < domains.length; j++) {
        if (host === domains[j] || host.slice(-(domains[j].length + 1)) === "." + domains[j]) return names[i];
      }
    }
    return null;
  }

  function formatBytes(n) {
    if (n === null || n === undefined || !isFinite(n) || n < 0) return null;
    var units = ["B", "KB", "MB", "GB"];
    var size = Number(n);
    var i = 0;
    while (size >= 1024 && i < units.length - 1) {
      size /= 1024;
      i++;
    }
    return (i === 0 ? String(Math.round(size)) : size.toFixed(1)) + " " + units[i];
  }

  function formatDuration(seconds) {
    var s = Math.max(0, Math.round(seconds || 0));
    var h = Math.floor(s / 3600);
    var m = Math.floor((s % 3600) / 60);
    var sec = s % 60;
    var pad = function (v) {
      return String(v).padStart(2, "0");
    };
    return h > 0 ? h + ":" + pad(m) + ":" + pad(sec) : m + ":" + pad(sec);
  }

  function formatEta(seconds) {
    if (seconds === null || seconds === undefined || !isFinite(seconds)) return "";
    return seconds >= 60 ? Math.floor(seconds / 60) + "m " + (seconds % 60) + "s left" : seconds + "s left";
  }

  /** Turn a server job into what the UI shows. Pure. */
  function describeJob(job) {
    var status = job.status;
    var progress = job.progress || {};
    var detail = [];
    var percent = Math.max(0, Math.min(100, Number(progress.percent) || 0));
    var label = STATUS_LABELS[status] || status;

    if (status === "downloading") {
      label = "Downloading " + Math.round(percent) + "%";
      if (progress.speed_bps) detail.push(formatBytes(progress.speed_bps) + "/s");
      var eta = formatEta(progress.eta_seconds);
      if (eta) detail.push(eta);
    }
    if (status === "queued" && job.attempt > 0) {
      label = "Retrying (attempt " + (job.attempt + 1) + " of " + job.max_attempts + ")…";
    }
    if (status === "failed" || status === "interrupted" || status === "cancelled") {
      if (job.error && job.error.message) label = job.error.message;
    }
    var failedLike = status === "failed" || status === "interrupted" || status === "cancelled";
    var done = formatBytes(progress.downloaded_bytes);
    var total = formatBytes(progress.total_bytes);
    return {
      status: status,
      label: label,
      // headline is the status word alone; message is the server's explanation, shown separately.
      headline: failedLike ? STATUS_LABELS[status] : label,
      message: failedLike && job.error && job.error.message ? job.error.message : "",
      tone: status === "completed" ? "success" : failedLike ? "danger" : "active",
      sizeText: status === "downloading" && done && total ? done + " of " + total : "",
      detail: detail.join(" · "),
      percent: percent,
      indeterminate: ["queued", "validating", "fetching_metadata", "merging", "verifying"].indexOf(status) !== -1,
      terminal: TERMINAL.indexOf(status) !== -1,
      canCancel: TERMINAL.indexOf(status) === -1,
      canRetry: status === "failed" || status === "cancelled" || status === "interrupted",
      retryable: !(job.error && job.error.retryable === false) || status !== "failed",
    };
  }

  var PLATFORM_LABELS = { youtube: "YouTube", facebook: "Facebook", tiktok: "TikTok", twitter: "X", instagram: "Instagram" };

  /** "just now", "5 min ago", "3 h ago", "2 d ago". `now` is injectable for tests. */
  function formatAgo(timestampMs, now) {
    if (!isFinite(timestampMs)) return "";
    var seconds = Math.max(0, Math.round(((now === undefined ? Date.now() : now) - timestampMs) / 1000));
    if (seconds < 45) return "just now";
    if (seconds < 3600) return Math.max(1, Math.round(seconds / 60)) + " min ago";
    if (seconds < 86400) return Math.round(seconds / 3600) + " h ago";
    return Math.round(seconds / 86400) + " d ago";
  }

  /** Size label for a format option: "~210 MB" (estimate), "210 MB" (exact) or "size unknown". */
  function sizeLabel(option) {
    var pretty = formatBytes(option && option.size_bytes);
    if (!pretty) return "size unknown";
    return (option.size_estimated ? "~" : "") + pretty;
  }

  function messageFromError(body, fallback) {
    if (body && body.error && body.error.message) return body.error.message;
    return fallback || "Something went wrong.";
  }

  /** Thin API client. `fetchImpl` is injectable for tests. */
  function createApi(fetchImpl, options) {
    options = options || {};
    var base = options.base || "";
    var apiKey = options.apiKey || null;

    function headers(extra) {
      var h = Object.assign({ "Content-Type": "application/json" }, extra || {});
      if (apiKey) h["X-API-Key"] = apiKey;
      return h;
    }

    function request(method, path, body, extraHeaders) {
      return fetchImpl(base + path, {
        method: method,
        headers: headers(extraHeaders),
        body: body === undefined ? undefined : JSON.stringify(body),
      }).then(function (res) {
        return res
          .json()
          .catch(function () {
            return null;
          })
          .then(function (data) {
            if (!res.ok) {
              var err = new Error(messageFromError(data, "Request failed (" + res.status + ")."));
              err.status = res.status;
              err.code = data && data.error ? data.error.code : null;
              err.retryable = data && data.error ? data.error.retryable : false;
              throw err;
            }
            return data;
          });
      });
    }

    var prefix = "/api/v1/downloads";
    var api = {
      metadata: function (url) {
        return request("POST", prefix + "/metadata", { url: url });
      },
      create: function (url, quality, idempotencyKey) {
        return request("POST", prefix, { url: url, quality: quality }, idempotencyKey ? { "Idempotency-Key": idempotencyKey } : {});
      },
      get: function (id) {
        return request("GET", prefix + "/" + encodeURIComponent(id));
      },
      cancel: function (id) {
        return request("POST", prefix + "/" + encodeURIComponent(id) + "/cancel");
      },
      // Desktop app only (the routes exist when the server runs in desktop mode).
      // The custom header forces a CORS preflight, so other websites cannot call these.
      desktopPrefs: function () {
        return request("GET", "/api/v1/desktop/preferences", undefined, DESKTOP_HEADER);
      },
      desktopSetPrefs: function (outputDir, autoSave) {
        return request("PUT", "/api/v1/desktop/preferences", { output_dir: outputDir, auto_save: autoSave }, DESKTOP_HEADER);
      },
      desktopSave: function (id) {
        return request("POST", "/api/v1/desktop/jobs/" + encodeURIComponent(id) + "/save", undefined, DESKTOP_HEADER);
      },
      desktopOpenFolder: function () {
        return request("POST", "/api/v1/desktop/open-folder", undefined, DESKTOP_HEADER);
      },
      /** Readiness report. Resolves with {httpStatus, body} for 200 *and* 503 (degraded is still informative). */
      health: function () {
        return fetchImpl(base + "/health/ready", { method: "GET", headers: headers() }).then(function (res) {
          return res
            .json()
            .catch(function () {
              return null;
            })
            .then(function (body) {
              return { httpStatus: res.status, body: body };
            });
        });
      },
      fileUrl: function (id) {
        return base + prefix + "/" + encodeURIComponent(id) + "/file";
      },
      /**
       * Follow a job until it is terminal. Uses server-sent events when
       * available (and no API key header is needed), otherwise polls.
       * Returns a function that stops watching.
       */
      watch: function (id, onUpdate, deps) {
        deps = deps || {};
        var EventSourceImpl = deps.EventSource || (typeof EventSource !== "undefined" ? EventSource : null);
        var setTimeoutImpl = deps.setTimeout || setTimeout;
        var clearTimeoutImpl = deps.clearTimeout || clearTimeout;
        var pollMs = deps.pollMs || 1000;
        var stopped = false;
        var source = null;
        var timer = null;
        var failures = 0;

        function finished(job) {
          return TERMINAL.indexOf(job.status) !== -1;
        }

        function poll() {
          if (stopped) return;
          api
            .get(id)
            .then(function (job) {
              failures = 0;
              if (stopped) return;
              onUpdate(job);
              if (!finished(job)) timer = setTimeoutImpl(poll, pollMs);
            })
            .catch(function (err) {
              if (stopped) return;
              failures++;
              // Not-found / auth errors are final; network blips are retried a few times.
              if (err.status === 404 || err.status === 401 || failures > 5) {
                onUpdate({ status: "failed", progress: {}, error: { code: "client_error", message: err.message, retryable: true, http_status: err.status || 0 } });
                return;
              }
              timer = setTimeoutImpl(poll, pollMs * (failures + 1));
            });
        }

        if (EventSourceImpl && !apiKey) {
          source = new EventSourceImpl(base + prefix + "/" + encodeURIComponent(id) + "/progress");
          source.addEventListener("job", function (event) {
            var job;
            try {
              job = JSON.parse(event.data);
            } catch (e) {
              return;
            }
            onUpdate(job);
            if (finished(job)) {
              source.close();
              source = null;
            }
          });
          source.onerror = function () {
            // Connection dropped (or proxy buffers SSE): fall back to polling, which is always correct.
            if (source) {
              source.close();
              source = null;
            }
            if (!stopped) poll();
          };
        } else {
          poll();
        }

        return function stop() {
          stopped = true;
          if (source) source.close();
          if (timer) clearTimeoutImpl(timer);
        };
      },
    };
    return api;
  }

  return {
    detectPlatform: detectPlatform,
    formatBytes: formatBytes,
    formatDuration: formatDuration,
    formatEta: formatEta,
    describeJob: describeJob,
    createApi: createApi,
    formatAgo: formatAgo,
    sizeLabel: sizeLabel,
    PLATFORM_LABELS: PLATFORM_LABELS,
    TERMINAL: TERMINAL,
  };
});
