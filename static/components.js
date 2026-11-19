/*
 * Reusable UI pieces: download row, format row, empty state, keyed list.
 * Every number and state a download row shows comes from the stored server job record.
 *
 * Depends on: NamaoApp (describeJob & formatters), NamaoHistory (bucket/isExpired), NamaoDom.
 */
(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory(require("./app.js"), require("./history.js"), require("./dom.js"));
  } else {
    root.NamaoUI = factory(root.NamaoApp, root.NamaoHistory, root.NamaoDom);
  }
})(typeof self !== "undefined" ? self : this, function (App, History, Dom) {
  "use strict";

  const { h, icon } = Dom;

  function platformChip(platform) {
    if (!platform) return null;
    return h("span", { class: "chip chip-platform", "data-platform": platform },
      h("span", { class: "dot", "aria-hidden": "true" }),
      Object.prototype.hasOwnProperty.call(App.PLATFORM_LABELS, platform) ? App.PLATFORM_LABELS[platform] : String(platform));
  }

  function entryTitle(entry) {
    return entry.title || "Untitled video";
  }

  /** Visible words describing where an entry is, derived only from stored server state. */
  function describeEntry(entry, now) {
    const view = App.describeJob({
      status: entry.status, progress: entry.progress, attempt: entry.attempt, max_attempts: entry.maxAttempts, error: entry.error,
    });
    const expired = History.isExpired(entry, now);
    if (entry.status === "completed") {
      const parts = [];
      if (entry.result && entry.result.height) parts.push(entry.result.height + "p");
      if (entry.result && entry.result.size_bytes) parts.push(App.formatBytes(entry.result.size_bytes));
      return {
        view, expired, tone: expired ? "neutral" : "success",
        headline: expired ? "Expired" : entry.saved ? "Saved" : "Ready",
        detail: expired ? "" : parts.join(" · "),
        message: expired ? "The server has removed this file. Download it again to get a new copy." : "",
      };
    }
    return { view, expired: false, tone: view.tone, headline: view.headline, detail: [view.sizeText, view.detail].filter(Boolean).join(" · "), message: view.message };
  }

  /** Which action buttons an entry offers (pure, so it can be tested). */
  function actionsFor(entry, info, desktop) {
    // A cancelled or interrupted job can always be started again; a failed one only if the server says it may succeed.
    const mayRetry = entry.status !== "failed" || !entry.error || entry.error.retryable !== false;
    const retryable = !!entry.url && mayRetry;
    if (!History.isTerminal(entry)) return ["cancel"];
    if (entry.status === "completed") {
      if (info.expired) return entry.url ? ["again", "remove"] : ["remove"];
      if (desktop) return entry.saved ? ["open-folder", "save", "remove"] : ["save-folder", "save", "remove"];
      return ["save", "remove"];
    }
    return retryable ? ["retry", "remove"] : ["remove"];
  }

  /**
   * One download row. `update(entry)` mutates text/attributes in place and only rebuilds the action
   * buttons when the set of actions changes, so a progress tick never steals keyboard focus.
   */
  function downloadItem(entry, ctx) {
    const thumbImg = h("img", { alt: "", width: 96, height: 54, loading: "lazy", decoding: "async", referrerpolicy: "no-referrer" });
    const thumbIcon = h("span", { class: "dl-thumb-icon" }, icon("video", 22));
    const thumb = h("div", { class: "dl-thumb" }, thumbImg, thumbIcon);
    thumbImg.addEventListener("error", () => thumb.classList.remove("has-image"));
    const title = h("div", { class: "dl-title" });
    const meta = h("div", { class: "dl-meta" });
    const state = h("span", { class: "dl-state" });
    const detail = h("span", { class: "dl-detail num" });
    const fill = h("span", { class: "bar-fill" });
    const bar = h("div", { class: "bar", role: "progressbar", "aria-valuemin": 0, "aria-valuemax": 100 }, fill);
    const message = h("p", { class: "dl-message" });
    const actions = h("div", { class: "dl-actions" });
    const el = h("li", { class: "dl-item", "data-id": entry.id },
      thumb, h("div", { class: "dl-main" }, title, meta, h("div", { class: "dl-statusline" }, state, detail), bar, message), actions);
    let actionSig = "";
    let current = entry;

    function button(kind, label, iconName, onClick, extraClass) {
      return h("button", {
        type: "button", class: "btn " + (extraClass || "btn-secondary"), onclick: onClick,
        "aria-label": label + ": " + entryTitle(current),
      }, icon(iconName, 16), h("span", { text: kind }));
    }

    function buildActions(list) {
      const nodes = list.map((name) => {
        switch (name) {
          case "cancel": return button("Cancel", "Cancel download", "x", () => ctx.onCancel(current), "btn-ghost");
          case "retry": return button("Retry", "Retry download", "retry", () => ctx.onRetry(current));
          case "again": return button("Download again", "Download again", "retry", () => ctx.onRetry(current), "btn-primary");
          case "save-folder": return button("Save to folder", "Save to folder", "folder", () => ctx.onSaveFolder(current), "btn-primary");
          case "open-folder": return button("Open folder", "Open folder", "folder", () => ctx.onOpenFolder(), "btn-secondary");
          case "remove":
            return h("button", {
              type: "button", class: "btn btn-icon btn-ghost", title: "Remove from history",
              "aria-label": "Remove from history: " + entryTitle(current), onclick: () => ctx.onRemove(current),
            }, icon("trash", 16));
          case "save":
            return h("a", {
              class: "btn " + (list.indexOf("save-folder") === -1 ? "btn-primary" : "btn-secondary"),
              href: ctx.fileUrl(current.id), download: current.result ? current.result.filename : "video",
              "aria-label": "Save file: " + entryTitle(current),
              onclick: (event) => ctx.onSaveFile(current, event),
            }, icon("download", 16), h("span", { text: "Save file" }));
          default: return null;
        }
      });
      const hadFocus = actions.contains(document.activeElement);
      actions.replaceChildren(...nodes.filter(Boolean));
      if (hadFocus) {
        const next = actions.querySelector("button, a");
        if (next) next.focus({ preventScroll: true });
        else Dom.focusFallback();
      }
    }

    function update(next) {
      current = next;
      const info = describeEntry(next, ctx.now());
      el.dataset.status = next.status;
      el.dataset.tone = info.tone;
      title.textContent = entryTitle(next);
      title.title = entryTitle(next);
      if (next.thumbnail) {
        if (thumbImg.getAttribute("src") !== next.thumbnail) thumbImg.setAttribute("src", next.thumbnail);
        thumb.classList.add("has-image");
      } else thumb.classList.remove("has-image");

      meta.replaceChildren(
        ...[platformChip(next.platform),
          next.qualityLabel ? h("span", { class: "chip", text: next.qualityLabel }) : null,
          h("span", { class: "dl-ago", text: App.formatAgo(next.createdAt, ctx.now()) })].filter(Boolean));

      state.textContent = info.headline;
      detail.textContent = info.detail;
      message.textContent = info.message;
      message.hidden = !info.message;

      const active = !History.isTerminal(next);
      bar.hidden = !active;
      if (active) {
        const determinate = !info.view.indeterminate;
        bar.classList.toggle("indeterminate", !determinate);
        if (determinate) {
          bar.setAttribute("aria-valuenow", String(Math.round(info.view.percent)));
          fill.style.transform = "scaleX(" + info.view.percent / 100 + ")";
        } else {
          bar.removeAttribute("aria-valuenow");
          fill.style.transform = "";
        }
        bar.setAttribute("aria-label", info.headline);
      }

      const list = actionsFor(next, info, ctx.desktop());
      const sig = list.join("|") + "|" + next.id;
      if (sig !== actionSig) {
        actionSig = sig;
        buildActions(list);
      }
    }

    update(entry);
    return { el, update };
  }

  /** A selectable quality row (native radio, so keyboard and screen readers work for free). */
  function formatRow(option, state) {
    const input = h("input", {
      type: "radio", name: state.name, value: option.id, checked: state.selected, onchange: () => state.onSelect(option),
    });
    const row = h("label", { class: "fmt-row" + (state.selected ? " selected" : "") },
      input,
      h("span", { class: "fmt-radio", "aria-hidden": "true" }),
      h("span", { class: "fmt-icon" }, icon(option.kind === "audio" ? "music" : "video", 16)),
      h("span", { class: "fmt-label", text: option.label }),
      option.note ? h("span", { class: "chip chip-accent", text: option.note }) : null,
      h("span", { class: "fmt-size num", text: App.sizeLabel(option) }));
    return row;
  }

  function emptyState(opts) {
    return h("div", { class: "empty" },
      h("span", { class: "empty-icon" }, icon(opts.icon || "inbox", 22)),
      h("h3", { class: "empty-title", text: opts.title }),
      h("p", { class: "empty-body", text: opts.body }),
      opts.action ? h("a", { class: "btn btn-secondary", href: opts.action.href, text: opts.action.label }) : null);
  }

  /** Keeps a container's children in sync with an ordered entry list, reusing existing rows by id. */
  function createReconciler(container, makeItem) {
    const items = new Map();
    return {
      render(entries) {
        const keep = new Set(entries.map((entry) => entry.id));
        items.forEach((item, id) => {
          if (!keep.has(id)) {
            item.el.remove();
            items.delete(id);
          }
        });
        let cursor = container.firstElementChild;
        entries.forEach((entry) => {
          let item = items.get(entry.id);
          if (!item) {
            item = makeItem(entry);
            items.set(entry.id, item);
          } else item.update(entry);
          if (item.el === cursor) cursor = cursor.nextElementSibling;
          else container.insertBefore(item.el, cursor);
        });
      },
    };
  }

  return { platformChip, describeEntry, actionsFor, downloadItem, formatRow, emptyState, createReconciler };
});
