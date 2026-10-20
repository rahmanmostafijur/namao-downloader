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
    return {
      status: status,
      label: label,
      detail: detail.join(" · "),
      percent: percent,
      indeterminate: ["queued", "validating", "fetching_metadata", "merging", "verifying"].indexOf(status) !== -1,
      terminal: TERMINAL.indexOf(status) !== -1,
      canCancel: TERMINAL.indexOf(status) === -1,
      canRetry: status === "failed" || status === "cancelled" || status === "interrupted",
      retryable: !(job.error && job.error.retryable === false) || status !== "failed",
    };
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
                onUpdate({ status: "failed", progress: {}, error: { code: "client_error", message: err.message, retryable: true } });
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

  /* ----------------------------------------------------------------------
   * DOM wiring (browser only)
   * -------------------------------------------------------------------- */
  function init(doc) {
    var $ = function (id) {
      return doc.getElementById(id);
    };
    var urlInput = $("url");
    if (!urlInput) return;

    var storedKey = null;
    try {
      storedKey = localStorage.getItem("namao-api-key");
    } catch (e) {
      /* storage blocked: fine */
    }
    var api = createApi(function (u, o) {
      return fetch(u, o);
    }, { apiKey: storedKey });

    var els = {
      pill: $("platform-pill"), paste: $("paste-btn"), fetch: $("fetch-btn"), status: $("status"),
      error: $("error"), banner: $("ffmpeg-banner"), result: $("result"), skeleton: $("skeleton"),
      thumb: $("thumb"), title: $("title"), sub: $("sub"), qualities: $("qualities"),
      themeMeta: $("theme-color-meta"), themeToggle: $("theme-toggle"),
    };
    var PLATFORM_LABELS = { youtube: "YouTube", facebook: "Facebook", tiktok: "TikTok", twitter: "X", instagram: "Instagram" };
    var PLATFORM_COLORS = { youtube: "#ff0033", facebook: "#0866ff", tiktok: "#0eb8b8", twitter: "#7c8591", instagram: "#e1306c" };
    var NEUTRAL = "#52525b";
    var watchers = [];

    function applyPlatformTint() {
      var platform = detectPlatform(urlInput.value);
      doc.body.setAttribute("data-platform", platform || "");
      els.pill.textContent = platform ? PLATFORM_LABELS[platform] : "";
      els.pill.classList.toggle("show", !!platform);
      els.themeMeta.setAttribute("content", platform ? PLATFORM_COLORS[platform] : NEUTRAL);
    }
    urlInput.addEventListener("input", applyPlatformTint);

    // theme
    var THEME_KEY = "namao-theme";
    function applyTheme(theme) {
      if (theme === "light") {
        doc.documentElement.setAttribute("data-theme", "light");
        els.themeToggle.textContent = "☀️";
      } else {
        doc.documentElement.removeAttribute("data-theme");
        els.themeToggle.textContent = "🌙";
      }
    }
    var savedTheme = null;
    try {
      savedTheme = localStorage.getItem(THEME_KEY);
    } catch (e) {
      /* ignore */
    }
    applyTheme(savedTheme === "light" ? "light" : "dark");
    els.themeToggle.addEventListener("click", function () {
      var next = doc.documentElement.getAttribute("data-theme") === "light" ? "dark" : "light";
      try {
        localStorage.setItem(THEME_KEY, next);
      } catch (e) {
        /* ignore */
      }
      applyTheme(next);
    });

    els.paste.addEventListener("click", function () {
      navigator.clipboard
        .readText()
        .then(function (text) {
          if (text) {
            urlInput.value = text.trim();
            applyPlatformTint();
            urlInput.focus();
          }
        })
        .catch(function () {
          showError("Couldn't read the clipboard automatically — paste with Ctrl+V instead.");
        });
    });

    function setStatus(text) {
      els.status.style.display = text ? "block" : "none";
      els.status.textContent = "";
      if (text) {
        var spinner = doc.createElement("span");
        spinner.className = "spinner";
        els.status.appendChild(spinner);
        els.status.appendChild(doc.createTextNode(text));
      }
    }
    function showError(text) {
      els.error.style.display = text ? "block" : "none";
      els.error.textContent = text || "";
    }

    function stopWatchers() {
      watchers.forEach(function (stop) {
        stop();
      });
      watchers = [];
    }

    /* ---- one quality row, driven entirely by server job state ---- */
    function renderRow(option, sourceUrl) {
      var row = doc.createElement("div");
      row.className = "quality-row";

      var label = doc.createElement("span");
      label.className = "quality-label";
      label.textContent = option.label;
      row.appendChild(label);

      if (option.note) {
        var note = doc.createElement("span");
        note.className = "quality-note";
        note.textContent = option.note;
        row.appendChild(note);
      }

      var size = doc.createElement("span");
      size.className = "quality-size";
      var pretty = formatBytes(option.size_bytes);
      size.textContent = pretty ? "~" + pretty : "size unknown";
      row.appendChild(size);

      var action = doc.createElement("span");
      action.className = "row-action";
      row.appendChild(action);
      showStart(action, option, sourceUrl);
      return row;
    }

    function button(text, className, onClick) {
      var b = doc.createElement("button");
      b.type = "button";
      b.className = className;
      b.textContent = text;
      b.addEventListener("click", onClick);
      return b;
    }

    function showStart(action, option, sourceUrl) {
      action.textContent = "";
      action.appendChild(button("Download", "dl-btn", function () {
        startJob(action, option, sourceUrl);
      }));
    }

    function startJob(action, option, sourceUrl) {
      action.textContent = "";
      var starting = doc.createElement("span");
      starting.className = "job-label";
      starting.textContent = "Starting…";
      action.appendChild(starting);
      var key = (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random().toString(16).slice(2));
      api
        .create(sourceUrl, option.id, key)
        .then(function (job) {
          watchJob(action, option, sourceUrl, job);
        })
        .catch(function (err) {
          showFailure(action, option, sourceUrl, err.message, true);
        });
    }

    function showFailure(action, option, sourceUrl, message, canRetry) {
      action.textContent = "";
      var text = doc.createElement("span");
      text.className = "job-label job-error";
      text.textContent = message;
      action.appendChild(text);
      if (canRetry) {
        action.appendChild(button("Retry", "dl-btn", function () {
          startJob(action, option, sourceUrl);
        }));
      }
    }

    function watchJob(action, option, sourceUrl, initial) {
      var jobId = initial.id;
      var bar, labelEl, detailEl, cancelBtn;

      function buildProgress() {
        action.textContent = "";
        var wrap = doc.createElement("span");
        wrap.className = "job-progress";
        labelEl = doc.createElement("span");
        labelEl.className = "job-label";
        bar = doc.createElement("progress");
        bar.max = 100;
        detailEl = doc.createElement("span");
        detailEl.className = "job-detail";
        cancelBtn = button("Cancel", "dl-btn dl-cancel", function () {
          cancelBtn.disabled = true;
          api.cancel(jobId).catch(function (err) {
            showError(err.message);
            cancelBtn.disabled = false;
          });
        });
        wrap.appendChild(labelEl);
        wrap.appendChild(bar);
        wrap.appendChild(detailEl);
        action.appendChild(wrap);
        action.appendChild(cancelBtn);
      }

      function render(job) {
        var view = describeJob(job);
        if (view.status === "completed" && job.result) {
          action.textContent = "";
          var info = doc.createElement("span");
          info.className = "job-label";
          info.textContent = job.result.height ? job.result.height + "p · " + formatBytes(job.result.size_bytes) : formatBytes(job.result.size_bytes);
          action.appendChild(info);
          var link = doc.createElement("a");
          link.className = "dl-btn";
          link.textContent = "Save file";
          link.href = api.fileUrl(jobId);
          link.setAttribute("download", job.result.filename || "video");
          action.appendChild(link);
          link.click(); // the server only ever offers a file after FFprobe verification
          return;
        }
        if (view.terminal) {
          var allowRetry = view.canRetry && (job.error ? job.error.retryable !== false : true);
          showFailure(action, option, sourceUrl, view.label, allowRetry || view.status === "cancelled");
          return;
        }
        if (!bar) buildProgress();
        labelEl.textContent = view.label;
        detailEl.textContent = view.detail;
        if (view.indeterminate) bar.removeAttribute("value");
        else bar.value = view.percent;
      }

      render(initial);
      watchers.push(api.watch(jobId, render));
    }

    function renderResult(data, sourceUrl) {
      els.result.style.display = "block";
      els.banner.style.display = data.ffmpeg ? "none" : "block";
      els.thumb.removeAttribute("src");
      if (typeof data.thumbnail === "string" && /^https:\/\//i.test(data.thumbnail)) els.thumb.src = data.thumbnail;
      els.title.textContent = data.title;
      els.sub.textContent = [data.uploader, formatDuration(data.duration_seconds)].filter(Boolean).join(" · ");
      els.qualities.textContent = "";
      data.formats.forEach(function (option) {
        els.qualities.appendChild(renderRow(option, sourceUrl));
      });
    }

    function fetchInfo() {
      var url = urlInput.value.trim();
      showError("");
      stopWatchers();
      els.result.style.display = "none";
      if (!url) return showError("Paste a video link first.");
      if (!detectPlatform(url)) {
        return showError("That link doesn't look like YouTube, Facebook, TikTok, X/Twitter, or Instagram.");
      }
      els.fetch.disabled = true;
      urlInput.disabled = true;
      setStatus("Reading video info…");
      els.skeleton.style.display = "block";
      api
        .metadata(url)
        .then(function (data) {
          renderResult(data, url);
        })
        .catch(function (err) {
          showError(err.status ? err.message : "Couldn't reach the server. Is it still running?");
        })
        .then(function () {
          setStatus("");
          els.skeleton.style.display = "none";
          els.fetch.disabled = false;
          urlInput.disabled = false;
        });
    }

    els.fetch.addEventListener("click", fetchInfo);
    urlInput.addEventListener("keydown", function (e) {
      if (e.key === "Enter") fetchInfo();
    });
    applyPlatformTint();
  }

  if (typeof document !== "undefined") {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", function () { init(document); });
    else init(document);
  }

  return {
    detectPlatform: detectPlatform,
    formatBytes: formatBytes,
    formatDuration: formatDuration,
    formatEta: formatEta,
    describeJob: describeJob,
    createApi: createApi,
    TERMINAL: TERMINAL,
  };
});
