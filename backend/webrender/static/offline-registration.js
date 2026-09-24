// Registers the optional public offline page's service worker without touching the authenticated
// app bootstrap.

(function () {
  "use strict";
  if (!window.isSecureContext || !("serviceWorker" in navigator)) return;
  navigator.serviceWorker.register("/static/service-worker.js", {
    scope: "/",
    updateViaCache: "none",
  }).catch(function () {
    console.warn("AstralDeep offline page could not be enabled.");
  });
}());
