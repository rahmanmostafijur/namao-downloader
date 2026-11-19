/*
 * Namao web client controller: routing, theme, the downloader flow, job tracking, settings.
 * Every state shown comes from the server's job record (via the history store); nothing is simulated.
 */
(function () {
  "use strict";

  const App = window.NamaoApp;
  const History = window.NamaoHistory;
  const UI = window.NamaoUI;
  const { h, icon, clear, focusFallback, toast, confirmDialog } = window.NamaoDom;
  const keepFocus = () => {
    if (document.activeElement === document.body || !document.activeElement) focusFallback();
  };
  const $ = (id) => document.getElementById(id);

  const THEME_KEY = "namao-theme";
  const API_KEY_KEY = "namao-api-key";
  const THEME_COLORS = { dark: "#0B0C0F", light: "#F6F5F2" };
  const THEME_ORDER = ["system", "light", "dark"];
  const THEME_ICONS = { system: "monitor", light: "sun", dark: "moon" };
  const HOME_ACTIVE_LIMIT = 3;
  const TITLES = { home: "Download", downloads: "Downloads", settings: "Settings", about: "About" };
  const ROUTES = { "": "home", "/": "home", "/downloads": "downloads", "/settings": "settings", "/about": "about" };
  const EMPTY_STATES = {
    active: { icon: "download", title: "Nothing downloading", body: "Paste a link on the Download page and your jobs appear here with live progress.", action: { href: "#/", label: "Start a download" } },
    completed: { icon: "check", title: "No finished downloads yet", body: "Completed downloads show up here. Save them before the server removes them." },
    failed: { icon: "alert", title: "No failed downloads", body: "Failed, cancelled and interrupted downloads would appear here with a Retry button." },
  };

  function storageGet(key) {
    try {
      return localStorage.getItem(key);
    } catch (e) {
      return null;
    }
  }
  function storageSet(key, value) {
    try {
      if (value === null) localStorage.removeItem(key);
      else localStorage.setItem(key, value);
    } catch (e) {
      /* storage blocked: the setting simply won't persist */
    }
  }
  const safeStorage = (() => {
    try {
      return window.localStorage;
    } catch (e) {
      return null;
    }
  })();

  /* ------------------------------------------------------------------ state */

  const history = History.createStore(safeStorage);
  let api = makeApi();
  const watchers = new Map();
  let desktop = null;
  let meta = null; // {data, url, selected}
  let fetchSeq = 0;
  let starting = false;
  let currentTab = "active";
  let lostContactNotified = false;
  let recoveryTimer = null;
  let desktopReady = Promise.resolve(); // settles once we know whether this is the desktop app
  const retrying = new Set(); // entry ids with a retry request in flight
  const AUTOSAVED_KEY = "namao-autosaved";
  const RECOVERY_DELAY_MS = 20000;
  const REFRESH_EVERY_MS = 30000;

  /** Several tabs can watch one job; exactly one may auto-save it. The first to record the id wins. */
  function claimAutoSave(id) {
    try {
      const parsed = JSON.parse(storageGet(AUTOSAVED_KEY) || "[]");
      const claimed = Array.isArray(parsed) ? parsed : [];
      if (claimed.indexOf(id) !== -1) return false;
      storageSet(AUTOSAVED_KEY, JSON.stringify(claimed.concat(id).slice(-200)));
    } catch (e) {
      /* unreadable claim list: better to save once too often than never */
    }
    return true;
  }

  function makeApi() {
    return App.createApi((url, options) => fetch(url, options), { apiKey: storageGet(API_KEY_KEY) });
  }

  const newKey = () => (window.crypto && crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random().toString(16).slice(2));
  const errorText = (err) => (err && err.status ? err.message : "Couldn't reach the server. Check that it is running and try again.");

  function announce(message) {
    const node = $("announcer");
    node.textContent = "";
    setTimeout(() => {
      node.textContent = message;
    }, 50);
  }

  /* ------------------------------------------------------------------ theme */

  const readTheme = () => {
    const value = storageGet(THEME_KEY);
    return value === "light" || value === "dark" ? value : "system";
  };
  const systemDark = () => window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  const effectiveTheme = (mode) => (mode === "system" ? (systemDark() ? "dark" : "light") : mode);

  function applyTheme(mode) {
    const root = document.documentElement;
    if (mode === "system") root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", mode);
    storageSet(THEME_KEY, mode === "system" ? null : mode);
    $("theme-color-meta").setAttribute("content", THEME_COLORS[effectiveTheme(mode)]);
    const toggle = $("theme-toggle");
    toggle.replaceChildren(icon(THEME_ICONS[mode], 18));
    toggle.setAttribute("aria-label", "Theme: " + mode + ". Activate to change.");
    toggle.title = "Theme: " + mode;
    document.querySelectorAll('input[name="theme"]').forEach((input) => {
      input.checked = input.value === mode;
    });
  }

  function setupTheme() {
    ["system", "light", "dark"].forEach((mode) => {
      const label = mode.charAt(0).toUpperCase() + mode.slice(1);
      $("theme-opt-" + mode).replaceChildren(icon(THEME_ICONS[mode], 16), label);
    });
    document.querySelectorAll('input[name="theme"]').forEach((input) => {
      input.addEventListener("change", () => applyTheme(input.value));
    });
    $("theme-toggle").addEventListener("click", () => {
      const next = THEME_ORDER[(THEME_ORDER.indexOf(readTheme()) + 1) % THEME_ORDER.length];
      applyTheme(next);
      announce("Theme set to " + next);
    });
    if (window.matchMedia) {
      window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
        if (readTheme() === "system") applyTheme("system");
      });
    }
    applyTheme(readTheme());
  }

  /* ----------------------------------------------------------------- router */

  const views = Array.from(document.querySelectorAll(".view"));

  const currentRoute = () => {
    const key = location.hash.replace(/^#/, "").split("?")[0];
    return Object.prototype.hasOwnProperty.call(ROUTES, key) ? ROUTES[key] : "home"; // "#constructor" must not resolve
  };

  function applyRoute(initial) {
    const name = currentRoute();
    views.forEach((view) => {
      view.hidden = view.dataset.view !== name;
    });
    document.querySelectorAll(".nav a").forEach((link) => {
      if (link.dataset.route === name) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    });
    document.title = TITLES[name] + " — Namao";
    renderAll();
    if (name === "settings") renderSettings();
    if (name === "about") loadVersion();
    if (!initial) {
      clear($("toasts")); // a toast belongs to the page it was raised on
      window.scrollTo(0, 0);
      const heading = document.querySelector('.view[data-view="' + name + '"] h1');
      if (heading) heading.focus({ preventScroll: true });
    }
  }

  function setupNav() {
    document.querySelectorAll(".nav a[data-icon]").forEach((link) => {
      link.insertBefore(icon(link.dataset.icon, 20), link.firstChild);
    });
    window.addEventListener("hashchange", () => applyRoute(false));
  }

  /* ----------------------------------------------------------- job tracking */

  const ctx = {
    now: () => Date.now(),
    desktop: () => desktop,
    fileUrl: (id) => api.fileUrl(id),
    onCancel: cancelJob,
    onRetry: retryJob,
    onRemove: removeEntry,
    onSaveFolder: saveToFolder,
    onOpenFolder: openFolder,
    onSaveFile: saveFile,
  };

  function track(job, details) {
    const entry = history.applyJob(job, details);
    if (entry && !History.isTerminal(entry)) watch(job.id);
    return entry;
  }

  function watch(id) {
    if (watchers.has(id)) return;
    const stop = api.watch(id, (job) => onJobUpdate(id, job));
    watchers.set(id, stop);
  }

  function unwatch(id) {
    const stop = watchers.get(id);
    if (stop) stop();
    watchers.delete(id);
  }

  function onJobUpdate(id, job) {
    const lost = job.error && job.error.code === "client_error";
    if (lost) return onLostContact(id, job.error);
    lostContactNotified = false;
    const before = history.get(id);
    const entry = history.applyJob({ ...job, id });
    if (!entry || !History.isTerminal(entry)) return;
    unwatch(id);
    if (entry.status === "completed" && before && !History.isTerminal(before)) onCompleted(entry);
    else if (entry.status === "failed") announce("Download failed: " + (entry.title || "video"));
  }

  /** The poller gave up. Only a 404 proves the job is gone; network trouble must not mark a running job failed. */
  function onLostContact(id, error) {
    unwatch(id);
    if (error.http_status === 404) {
      history.applyJob({ id, status: "failed", progress: {}, error: { code: "not_found", message: "This download is no longer on the server.", retryable: true } });
      return;
    }
    if (lostContactNotified) return;
    if (error.http_status === 401) {
      if (!lostContactNotified) toast("The server rejected the access key. Check Settings.", { tone: "danger" });
      lostContactNotified = true;
      return;
    }
    if (!lostContactNotified) toast("Lost contact with the server. Trying again shortly.", { tone: "danger" });
    lostContactNotified = true;
    // An outage on a visible, online tab fires no browser event, so poll for recovery ourselves.
    clearTimeout(recoveryTimer);
    recoveryTimer = setTimeout(resumeActive, RECOVERY_DELAY_MS);
  }

  function resumeActive() {
    history.list().forEach((entry) => {
      if (!History.isTerminal(entry)) watch(entry.id);
    });
  }

  function onCompleted(entry) {
    announce("Download ready: " + (entry.title || "video"));
    if (!claimAutoSave(entry.id)) return; // another tab already saved it
    // Wait for the desktop probe so a job finishing during page load still honours the chosen folder.
    desktopReady.then(() => {
      if (desktop && desktop.auto_save) saveToFolder(entry);
      else saveFile(entry);
    });
  }

  /** Browser save. A plain link cannot send the access key header, so keyed servers go through fetch + blob. */
  async function saveFile(entry, event) {
    const key = storageGet(API_KEY_KEY);
    const filename = entry.result && entry.result.filename ? entry.result.filename : "video";
    if (event && !key) return; // let the link's native download run
    if (event) event.preventDefault();
    try {
      let href = api.fileUrl(entry.id);
      let revoke = null;
      if (key) {
        const response = await fetch(href, { headers: { "X-API-Key": key } });
        if (!response.ok) throw new Error("The server did not return the file (" + response.status + ").");
        href = URL.createObjectURL(await response.blob());
        revoke = href;
      }
      const link = h("a", { href, download: filename });
      document.body.appendChild(link);
      link.click();
      link.remove();
      if (revoke) setTimeout(() => URL.revokeObjectURL(revoke), 60000);
    } catch (err) {
      toast(err.message || "Couldn't save the file.", { tone: "danger" });
    }
  }

  async function saveToFolder(entry) {
    try {
      const saved = await api.desktopSave(entry.id);
      history.markSaved(entry.id, saved.name);
      toast("Saved as " + saved.name, { tone: "success", action: { label: "Open folder", onClick: openFolder } });
    } catch (err) {
      toast(errorText(err), { tone: "danger" });
    }
  }

  function openFolder() {
    api.desktopOpenFolder().catch((err) => toast(errorText(err), { tone: "danger" }));
  }

  async function cancelJob(entry) {
    try {
      // Route through the normal update path: a terminal answer stops the watcher, and a job that
      // raced to "completed" still gets saved.
      onJobUpdate(entry.id, await api.cancel(entry.id));
    } catch (err) {
      toast(errorText(err), { tone: "danger" });
    }
  }

  async function retryJob(entry) {
    if (!entry.url || retrying.has(entry.id)) return; // a second click while the first is in flight would start a second job
    retrying.add(entry.id);
    try {
      const job = await api.create(entry.url, entry.quality, newKey());
      unwatch(entry.id);
      history.remove(entry.id);
      track(job, {
        url: entry.url, platform: entry.platform, title: entry.title, uploader: entry.uploader, thumbnail: entry.thumbnail,
        durationSeconds: entry.durationSeconds, quality: entry.quality, qualityLabel: entry.qualityLabel, createdAt: Date.now(),
      });
      toast("Download restarted");
    } catch (err) {
      toast(errorText(err), { tone: "danger" });
    } finally {
      retrying.delete(entry.id);
    }
  }

  async function removeEntry(entry) {
    const needsConfirm = entry.status === "completed" && !History.isExpired(entry);
    if (needsConfirm) {
      const ok = await confirmDialog({
        title: "Remove from history?",
        body: "This only clears the entry in this browser. Files you already saved are not deleted.",
        confirmLabel: "Remove", danger: true,
      });
      if (!ok) return;
    }
    unwatch(entry.id);
    history.remove(entry.id);
    keepFocus();
  }

  /* ------------------------------------------------------------- Home view */

  const urlInput = $("url");
  const homeList = UI.createReconciler($("home-active-list"), (entry) => UI.downloadItem(entry, ctx));
  const downloadsList = UI.createReconciler($("dl-list"), (entry) => UI.downloadItem(entry, ctx));

  function setUrlError(message) {
    const node = $("url-error");
    node.hidden = !message;
    node.textContent = message || "";
    $("url-field").toggleAttribute("data-invalid", !!message);
    urlInput.setAttribute("aria-invalid", message ? "true" : "false");
  }

  function syncUrlField() {
    const platform = App.detectPlatform(urlInput.value);
    const chip = $("platform-chip");
    chip.hidden = !platform;
    if (platform) {
      chip.dataset.platform = platform;
      chip.replaceChildren(h("span", { class: "dot", "aria-hidden": "true" }), App.PLATFORM_LABELS[platform]);
    }
    $("clear-btn").hidden = !urlInput.value;
  }

  function hideResult() {
    fetchSeq += 1; // any metadata request still in flight is now stale
    $("result").hidden = true;
    $("skeleton").hidden = true;
    $("server-banner").hidden = true;
    $("fetch-btn").disabled = false;
    $("fetch-btn").textContent = "Get formats";
    meta = null;
  }

  function setFetching(busy) {
    const button = $("fetch-btn");
    button.disabled = busy;
    button.textContent = busy ? "Reading…" : "Get formats";
    $("skeleton").hidden = !busy;
    $("url-form").setAttribute("aria-busy", busy ? "true" : "false");
    if (busy) announce("Reading video info");
  }

  async function fetchInfo() {
    const url = urlInput.value.trim();
    setUrlError("");
    hideResult();
    if (!url) return setUrlError("Paste a video link to get started.");
    if (!App.detectPlatform(url)) return setUrlError("That doesn’t look like a YouTube, Facebook, TikTok, X or Instagram link.");
    const seq = ++fetchSeq;
    setFetching(true);
    try {
      const data = await api.metadata(url);
      if (seq === fetchSeq) renderResult(data, url);
    } catch (err) {
      if (seq === fetchSeq) setUrlError(errorText(err));
    } finally {
      if (seq === fetchSeq) setFetching(false);
    }
  }

  function renderResult(data, url) {
    const formats = Array.isArray(data.formats) ? data.formats : [];
    if (!formats.length) return setUrlError("No downloadable formats were found for this video.");
    meta = { data, url, selected: formats[0], keys: {} };
    const thumb = $("thumb");
    if (typeof data.thumbnail === "string" && /^https:\/\//i.test(data.thumbnail)) thumb.src = data.thumbnail;
    else thumb.removeAttribute("src");
    $("duration-badge").textContent = App.formatDuration(data.duration_seconds);
    $("duration-badge").hidden = !data.duration_seconds;
    $("result-title").textContent = data.title;
    $("result-sub").textContent = data.uploader || "";
    $("result-chips").replaceChildren(UI.platformChip(data.platform));
    const banner = $("server-banner");
    banner.hidden = !!data.ffmpeg;
    banner.textContent = "This server can’t find FFmpeg, so merged video and audio downloads will fail. The operator needs to install it (see docs/deployment.md).";
    renderFormats(formats);
    $("result").hidden = false;
    announce(formats.length + " formats available");
  }

  function renderFormats(formats) {
    const groups = { video: $("fmt-video"), audio: $("fmt-audio") };
    Object.keys(groups).forEach((kind) => {
      const list = formats.filter((option) => option.kind === kind);
      clear(groups[kind]);
      $("group-" + kind).hidden = !list.length;
      list.forEach((option) => {
        groups[kind].appendChild(UI.formatRow(option, {
          name: "quality", selected: option.id === meta.selected.id,
          onSelect: (chosen) => {
            meta.selected = chosen;
            syncSelection();
          },
        }));
      });
    });
    syncSelection();
  }

  function syncSelection() {
    document.querySelectorAll("#format-form .fmt-row").forEach((row) => {
      row.classList.toggle("selected", row.querySelector("input").checked);
    });
    const option = meta.selected;
    $("selected-label").textContent = option.label + (option.note ? " · " + option.note : "");
    $("selected-size").textContent = App.sizeLabel(option);
    const button = $("download-btn");
    button.disabled = starting;
    button.replaceChildren(icon("download", 18), "Download " + option.label);
  }

  async function startDownload() {
    if (!meta || starting) return;
    starting = true;
    syncSelection();
    const { data, url, selected, keys } = meta;
    // Reuse the key until a create succeeds: if a response is lost and the user taps again, the server de-duplicates.
    const key = keys[selected.id] || (keys[selected.id] = newKey());
    try {
      const job = await api.create(url, selected.id, key);
      delete keys[selected.id];
      track(job, {
        url, platform: data.platform, title: data.title, uploader: data.uploader, thumbnail: data.thumbnail || "",
        durationSeconds: data.duration_seconds, quality: selected.id, qualityLabel: selected.label, createdAt: Date.now(),
      });
      toast("Added to Downloads", { action: { label: "View", onClick: () => { location.hash = "#/downloads"; } } });
    } catch (err) {
      toast(errorText(err), { tone: "danger" });
    } finally {
      starting = false;
      if (meta) syncSelection();
    }
  }

  function setupHome() {
    $("url-icon").appendChild(icon("link", 18));
    $("clear-btn").appendChild(icon("x", 18));
    $("paste-btn").replaceChildren(icon("paste", 18), "Paste");
    urlInput.addEventListener("input", () => {
      syncUrlField();
      setUrlError("");
      if (fetchSeq && !$("skeleton").hidden) {
        fetchSeq += 1;
        setFetching(false);
      }
    });
    $("clear-btn").addEventListener("click", () => {
      urlInput.value = "";
      syncUrlField();
      setUrlError("");
      hideResult();
      urlInput.focus();
    });
    $("paste-btn").addEventListener("click", async () => {
      try {
        const text = (await navigator.clipboard.readText()).trim();
        if (!text) return setUrlError("The clipboard is empty.");
        urlInput.value = text;
        syncUrlField();
        if (App.detectPlatform(text)) fetchInfo();
        else setUrlError("That doesn’t look like a YouTube, Facebook, TikTok, X or Instagram link.");
      } catch (e) {
        setUrlError("Couldn’t read the clipboard. Paste into the field with Ctrl+V (or ⌘V) instead.");
      }
    });
    $("url-form").addEventListener("submit", (event) => {
      event.preventDefault();
      fetchInfo();
    });
    $("format-form").addEventListener("submit", (event) => {
      event.preventDefault();
      startDownload();
    });
    syncUrlField();
  }

  /* --------------------------------------------------------- Downloads view */

  function setupTabs() {
    const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
    function select(name, focus) {
      currentTab = name;
      tabs.forEach((tab) => {
        const on = tab.dataset.tab === name;
        tab.setAttribute("aria-selected", on ? "true" : "false");
        tab.tabIndex = on ? 0 : -1;
        if (on) $("downloads-panel").setAttribute("aria-labelledby", tab.id);
        if (on && focus) tab.focus();
      });
      renderAll();
    }
    tabs.forEach((tab, index) => {
      tab.addEventListener("click", () => select(tab.dataset.tab, false));
      tab.addEventListener("keydown", (event) => {
        const move = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
        let target = null;
        if (move) target = tabs[(index + move + tabs.length) % tabs.length];
        else if (event.key === "Home") target = tabs[0];
        else if (event.key === "End") target = tabs[tabs.length - 1];
        if (!target) return;
        event.preventDefault();
        select(target.dataset.tab, true);
      });
    });
    $("clear-finished").addEventListener("click", async () => {
      const targets = history.list().filter((entry) => History.bucket(entry) === currentTab);
      if (!targets.length) return;
      const ok = await confirmDialog({
        title: "Clear " + targets.length + (targets.length === 1 ? " entry?" : " entries?"),
        body: "This only clears the list in this browser. Files you already saved are not deleted.",
        confirmLabel: "Clear", danger: true,
      });
      if (ok) history.removeWhere((entry) => History.bucket(entry) === currentTab);
      keepFocus();
    });
  }

  /* ----------------------------------------------------------------- render */

  function renderAll() {
    const entries = history.list();
    const counts = History.counts(entries);
    document.querySelectorAll("[data-count]").forEach((node) => {
      node.textContent = String(counts[node.dataset.count]);
    });
    const badge = $("nav-badge");
    badge.hidden = counts.active === 0;
    badge.textContent = String(counts.active);
    const link = document.querySelector('.nav a[data-route="downloads"]');
    link.setAttribute("aria-label", counts.active ? "Downloads, " + counts.active + " active" : "Downloads");

    const route = currentRoute();
    if (route === "home") {
      const active = entries.filter((entry) => History.bucket(entry) === "active").slice(0, HOME_ACTIVE_LIMIT);
      $("home-active").hidden = !active.length;
      homeList.render(active);
    }
    if (route === "downloads") {
      const shown = entries.filter((entry) => History.bucket(entry) === currentTab);
      downloadsList.render(shown);
      const empty = $("dl-empty");
      clear(empty);
      if (!shown.length) empty.appendChild(UI.emptyState(EMPTY_STATES[currentTab]));
      const clearButton = $("clear-finished");
      clearButton.hidden = !shown.length || currentTab === "active";
      clearButton.textContent = currentTab === "completed" ? "Clear completed" : "Clear failed";
    }
    if (route === "settings") renderHistoryHelp();
  }

  /* --------------------------------------------------------------- Settings */

  function renderHistoryHelp() {
    const n = history.list().length;
    $("history-help").textContent = n
      ? n + (n === 1 ? " download is" : " downloads are") + " remembered in this browser. Clearing removes the list only; saved files and running jobs are not affected."
      : "No downloads are remembered in this browser.";
    $("clear-history").disabled = n === 0;
  }

  function renderSettings() {
    renderHistoryHelp();
    $("api-key").placeholder = storageGet(API_KEY_KEY) ? "Key saved (hidden)" : "Not set";
  }

  const CHECK_LABELS = { engine: "Download engine", ffmpeg: "FFmpeg", ffprobe: "FFprobe", database: "Database", storage: "Storage", worker: "Worker" };

  function checkDetail(check) {
    if (check.version) return String(check.version).slice(0, 24);
    if (typeof check.free_mb === "number") return Math.round(check.free_mb / 1024) + " GB free";
    if (typeof check.alive === "number") return check.alive + " running";
    return "";
  }

  async function checkServer() {
    const summary = $("server-summary");
    const list = $("server-checks");
    const button = $("check-server");
    button.disabled = true;
    summary.removeAttribute("data-ok");
    summary.textContent = "Checking…";
    try {
      const { httpStatus, body } = await api.health();
      if (httpStatus === 401 || httpStatus === 403) {
        summary.dataset.ok = "false";
        summary.textContent = "The server requires a valid access key.";
        list.hidden = true;
        return;
      }
      const ok = body && body.status === "ready";
      summary.dataset.ok = ok ? "true" : "false";
      summary.textContent = ok ? "Ready" : "Degraded — some checks failed";
      clear(list);
      const checks = (body && body.checks) || {};
      Object.keys(checks).forEach((name) => {
        const check = checks[name];
        list.appendChild(h("li", { "data-ok": check.ok ? "true" : "false" },
          icon(check.ok ? "check" : "alert", 16),
          h("span", { text: CHECK_LABELS[name] || name }),
          h("span", { class: "check-detail num", text: checkDetail(check) })));
      });
      ((body && body.problems) || []).forEach((problem) => {
        list.appendChild(h("li", { "data-ok": "false" }, icon("alert", 16), h("span", { text: String(problem).slice(0, 160) })));
      });
      list.hidden = !list.children.length;
    } catch (e) {
      summary.dataset.ok = "false";
      summary.textContent = "Can’t reach the server.";
      list.hidden = true;
    } finally {
      button.disabled = false;
    }
  }

  function restartWatchers() {
    Array.from(watchers.keys()).forEach(unwatch);
    resumeActive();
  }

  function setupSettings() {
    $("check-server").addEventListener("click", checkServer);
    $("api-key-form").addEventListener("submit", (event) => {
      event.preventDefault();
      const value = $("api-key").value.trim();
      if (!value) return toast("Enter an access key first.", { tone: "danger" });
      storageSet(API_KEY_KEY, value);
      $("api-key").value = "";
      api = makeApi();
      restartWatchers();
      renderSettings();
      toast("Access key saved", { tone: "success" });
    });
    $("api-key-clear").addEventListener("click", () => {
      storageSet(API_KEY_KEY, null);
      $("api-key").value = "";
      api = makeApi();
      restartWatchers();
      renderSettings();
      toast("Access key removed");
    });
    $("clear-history").addEventListener("click", async () => {
      const ok = await confirmDialog({
        title: "Clear all history?",
        body: "This forgets every download in this browser. Files you already saved are not deleted, and running jobs keep running on the server.",
        confirmLabel: "Clear history", danger: true,
      });
      if (!ok) return;
      Array.from(watchers.keys()).forEach(unwatch);
      history.clear();
      toast("History cleared");
    });
    setupDesktopSettings();
  }

  function setupDesktopSettings() {
    const message = $("desktop-message");
    const fail = (err) => {
      message.hidden = false;
      message.textContent = errorText(err);
    };
    const update = (outputDir, autoSave) => api.desktopSetPrefs(outputDir, autoSave).then((prefs) => {
      desktop = prefs;
      message.hidden = true;
      $("desktop-folder").value = prefs.output_dir;
      $("desktop-autosave").checked = !!prefs.auto_save;
      renderAll();
      return prefs;
    });
    $("desktop-save-folder").addEventListener("click", () => {
      update($("desktop-folder").value.trim(), $("desktop-autosave").checked).then(() => toast("Save folder updated", { tone: "success" })).catch(fail);
    });
    $("desktop-autosave").addEventListener("change", (event) => {
      update(desktop.output_dir, event.target.checked).catch((err) => {
        event.target.checked = !event.target.checked;
        fail(err);
      });
    });
    $("desktop-open-folder").addEventListener("click", openFolder);
    // Only the desktop app has these endpoints; ask first so a plain web server isn't probed (and doesn't log a 404).
    desktopReady = fetch("/health/live")
      .then((response) => response.json())
      .then((body) => (body && body.desktop ? api.desktopPrefs() : null))
      .then((prefs) => {
        if (!prefs) return;
        desktop = prefs;
        $("desktop-card").hidden = false;
        $("desktop-folder").value = prefs.output_dir;
        $("desktop-autosave").checked = !!prefs.auto_save;
        renderAll();
      })
      .catch(() => { /* server unreachable or not the desktop app: nothing to set up */ });
  }

  async function loadVersion() {
    const node = $("about-version");
    try {
      const response = await fetch("/health/live");
      const body = await response.json();
      node.textContent = body && body.version ? "Server version " + body.version : "";
    } catch (e) {
      node.textContent = "";
    }
  }

  /* ------------------------------------------------------------------- boot */

  function boot() {
    setupTheme();
    setupNav();
    setupHome();
    setupTabs();
    setupSettings();
    history.subscribe(renderAll);
    window.addEventListener("online", resumeActive);
    // Another tab changed the history: follow it, and stop/start watching accordingly.
    window.addEventListener("storage", (event) => {
      if (event.key !== History.KEY && event.key !== null) return;
      history.adopt(event.newValue);
      const live = new Set(history.list().map((entry) => entry.id));
      Array.from(watchers.keys()).filter((id) => !live.has(id)).forEach(unwatch);
      resumeActive();
    });
    // "x min ago" labels and expiry must not go stale while the page stays open.
    setInterval(() => {
      if (document.visibilityState === "visible") renderAll();
    }, REFRESH_EVERY_MS);
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") resumeActive();
    });
    applyRoute(true);
    resumeActive();
  }

  boot();
})();
