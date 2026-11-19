/*
 * Small DOM toolkit for the Namao web client: element builder, icons, toasts, confirm dialog.
 * All text goes through text nodes / textContent and is never parsed as markup, so
 * server-provided strings (titles, error messages) cannot inject HTML.
 */
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.NamaoDom = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  const SVG_NS = "http://www.w3.org/2000/svg";

  // One icon family: 24px grid, 1.75 stroke, round caps. A string is a path; an array is [tag, attrs].
  const ICONS = {
    download: ["M12 4v11", "M7.5 10.5 12 15l4.5-4.5", "M5 20h14"],
    link: ["M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1", "M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"],
    paste: ["M9 4h6v3H9z", "M8 5.5H6.5A1.5 1.5 0 0 0 5 7v12a1.5 1.5 0 0 0 1.5 1.5h11A1.5 1.5 0 0 0 19 19V7a1.5 1.5 0 0 0-1.5-1.5H16"],
    x: ["M6 6l12 12", "M18 6 6 18"],
    check: ["M5 12.5 9.5 17 19 7.5"],
    retry: ["M20 11a8 8 0 1 0-2.3 6.3", "M20 5v6h-6"],
    folder: ["M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"],
    sliders: ["M4 7h9", "M17 7h3", "M4 17h3", "M11 17h9", "M13 4v6", "M7 14v6"],
    info: [["circle", { cx: 12, cy: 12, r: 9 }], "M12 11v5", "M12 8h.01"],
    sun: [["circle", { cx: 12, cy: 12, r: 4 }], "M12 3v2", "M12 19v2", "M3 12h2", "M19 12h2", "M5.6 5.6 7 7", "M17 17l1.4 1.4", "M5.6 18.4 7 17", "M17 7l1.4-1.4"],
    moon: ["M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5z"],
    monitor: ["M3 5h18v11H3z", "M8 20h8", "M12 16v4"],
    trash: ["M4 7h16", "M9 7V4h6v3", "M6 7l1 13h10l1-13", "M10 11v6", "M14 11v6"],
    music: ["M9 18V6l11-2v12", ["circle", { cx: 6.5, cy: 18, r: 2.5 }], ["circle", { cx: 17.5, cy: 16, r: 2.5 }]],
    video: ["M3.5 6h12v12h-12z", "M15.5 10 21 7v10l-5.5-3"],
    alert: ["M12 3.5 22 20.5H2z", "M12 10v5", "M12 18h.01"],
    list: ["M9 6h11", "M9 12h11", "M9 18h11", "M4.5 6h.01", "M4.5 12h.01", "M4.5 18h.01"],
    inbox: ["M4 13l2-7h12l2 7", "M4 13v6h16v-6", "M4 13h5l1 2h4l1-2h5"],
  };

  function svgEl(tag, attrs) {
    const el = document.createElementNS(SVG_NS, tag);
    Object.keys(attrs).forEach((k) => el.setAttribute(k, String(attrs[k])));
    return el;
  }

  /** Inline SVG icon. Decorative by default (aria-hidden); pair with visible text or an aria-label on the control. */
  function icon(name, size) {
    const px = size || 18;
    const svg = svgEl("svg", {
      class: "icon", width: px, height: px, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor",
      "stroke-width": 1.75, "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true", focusable: "false",
    });
    (ICONS[name] || []).forEach((part) => {
      svg.appendChild(typeof part === "string" ? svgEl("path", { d: part }) : svgEl(part[0], part[1]));
    });
    return svg;
  }

  function append(el, items) {
    items.forEach((child) => {
      if (child === null || child === undefined || child === false) return;
      if (Array.isArray(child)) append(el, child);
      else el.appendChild(typeof child === "object" ? child : document.createTextNode(String(child)));
    });
  }

  /** h("div", {class: "x", onclick: fn, "aria-label": "…"}, child, "text", [more]) */
  function h(tag, props) {
    const el = document.createElement(tag);
    const attrs = props || {};
    Object.keys(attrs).forEach((key) => {
      const value = attrs[key];
      if (value === null || value === undefined || value === false) return;
      if (key === "class") el.className = value;
      else if (key === "text") el.textContent = value;
      else if (key.slice(0, 2) === "on" && typeof value === "function") el.addEventListener(key.slice(2), value);
      else if (value === true) el.setAttribute(key, "");
      else el.setAttribute(key, String(value));
    });
    append(el, Array.prototype.slice.call(arguments, 2));
    return el;
  }

  function clear(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
  }

  /** When the focused control disappears, land on the visible page's heading instead of <body>. */
  function focusFallback() {
    const heading = document.querySelector(".view:not([hidden]) h1");
    if (heading) heading.focus({ preventScroll: true });
  }

  /* ----------------------------------------------------------------- toasts */

  const MAX_TOASTS = 3;

  /** Transient message in the polite live region. Options: {tone: "danger"|"success", action: {label, onClick}, ms}. */
  function toast(message, options) {
    const host = document.getElementById("toasts");
    if (!host) return { dismiss() {} };
    const opts = options || {};
    while (host.children.length >= MAX_TOASTS) host.removeChild(host.firstChild);
    let timer = null;
    const node = h("div", { class: "toast" + (opts.tone ? " toast-" + opts.tone : "") },
      h("span", { class: "toast-text", text: message }));
    function dismiss() {
      clearTimeout(timer);
      if (node.parentNode) node.parentNode.removeChild(node);
    }
    if (opts.action) {
      node.appendChild(h("button", {
        type: "button", class: "toast-action", text: opts.action.label,
        onclick() {
          dismiss();
          opts.action.onClick();
        },
      }));
    }
    host.appendChild(node);
    timer = setTimeout(dismiss, opts.ms || (opts.action ? 8000 : 4500));
    return { dismiss };
  }

  /* ----------------------------------------------------------- confirm dialog */

  /** Modal confirmation using the native <dialog> (focus trap, Esc, inert background). Resolves true/false. */
  function confirmDialog(options) {
    return new Promise((resolve) => {
      if (typeof HTMLDialogElement === "undefined") {
        resolve(window.confirm(options.title + "\n\n" + options.body));
        return;
      }
      const opener = document.activeElement;
      const titleId = "dlg-title-" + Math.random().toString(36).slice(2, 8);
      const dialog = h("dialog", { class: "dialog", "aria-labelledby": titleId },
        h("form", { method: "dialog" },
          h("h2", { id: titleId, class: "dialog-title", text: options.title }),
          h("p", { class: "dialog-body", text: options.body }),
          h("div", { class: "dialog-actions" },
            h("button", { class: "btn btn-secondary", value: "cancel", text: options.cancelLabel || "Cancel", autofocus: true }),
            h("button", { class: "btn " + (options.danger ? "btn-danger" : "btn-primary"), value: "confirm", text: options.confirmLabel || "Confirm" }))));
      dialog.addEventListener("close", () => {
        const confirmed = dialog.returnValue === "confirm";
        dialog.remove();
        if (opener && typeof opener.focus === "function" && document.contains(opener)) opener.focus();
        else focusFallback(); // the control that opened the dialog was removed by the action
        resolve(confirmed);
      });
      document.body.appendChild(dialog);
      dialog.showModal();
    });
  }

  return { h, icon, clear, focusFallback, toast, confirmDialog };
});
