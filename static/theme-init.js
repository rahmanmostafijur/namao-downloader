/* Applies the saved theme before first paint (loaded synchronously in <head>; external so the CSP can forbid inline scripts). */
(function () {
  "use strict";
  var theme = null;
  try {
    theme = localStorage.getItem("namao-theme");
  } catch (e) {
    /* storage blocked: follow the system setting */
  }
  if (theme === "light" || theme === "dark") document.documentElement.setAttribute("data-theme", theme);
})();
