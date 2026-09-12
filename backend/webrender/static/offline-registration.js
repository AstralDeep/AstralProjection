/* Optional public disconnected page; never changes the authenticated bootstrap. */
(function () {
  "use strict";
  if (!window.isSecureContext || !("serviceWorker" in navigator)) return;
  navigator.serviceWorker.register("/static/service-worker.js", {
    scope: "/",
    updateViaCache: "none",
  }).catch(function () {
    // No request URLs, credentials, or user state enter this diagnostic.
    console.warn("AstralDeep offline page could not be enabled.");
  });
}());
