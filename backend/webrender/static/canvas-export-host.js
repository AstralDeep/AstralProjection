/* Fixed bootstrap for the isolated, bundled export-only native document. */
(function () {
  "use strict";
  var state = document.documentElement;
  var result = { state: "loading" };
  var retired = false;
  window.AstralExportResult = result;
  function fail() {
    retired = true;
    window.AstralExportResult = Object.freeze({ state: "error", code: "export_render_unavailable" });
    state.dataset.exportState = "error";
    document.getElementById("export-status").textContent = "This canvas could not be exported. Open it in the web client.";
  }
  function exact(value, keys) {
    if (!value || typeof value !== "object" || Array.isArray(value) ||
        Object.keys(value).sort().join("|") !== keys.slice().sort().join("|")) throw new Error("Invalid fields");
  }
  async function start() {
    var raw = document.getElementById("export-payload").content;
    if (raw.length > 48 * 1024 * 1024) throw new Error("Large input");
    var bytes = Uint8Array.from(atob(raw), function (c) { return c.charCodeAt(0); });
    if (bytes.byteLength > 32 * 1024 * 1024) throw new Error("Large input");
    var input = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    document.getElementById("export-payload").remove();
    exact(input, ["version", "html", "viewport", "theme"]);
    if (input.version !== "astral.canvas-export/v1" || typeof input.html !== "string") throw new Error("Unsupported export");
    exact(input.viewport, ["width", "height", "window_width", "window_height"]);
    if (typeof input.viewport.width !== "number" || !Number.isFinite(input.viewport.width) || input.viewport.width < 64 || input.viewport.width > 4096 ||
        typeof input.viewport.height !== "number" || !Number.isFinite(input.viewport.height) || input.viewport.height < 32 || input.viewport.height > 16384) throw new Error("Invalid viewport");
    ["window_width", "window_height"].forEach(function (key) {
      if (typeof input.viewport[key] !== "number" || !Number.isFinite(input.viewport[key]) ||
          input.viewport[key] < (key === "window_width" ? 64 : 32) || input.viewport[key] > 16384) throw new Error("Invalid viewport");
    });
    if (input.viewport.width > input.viewport.window_width || Math.abs(innerWidth - input.viewport.window_width) > 1) throw new Error("Incorrect host viewport");
    var roles = ["bg", "surface", "surface2", "border", "primary", "secondary", "accent", "text", "muted", "success", "warning", "error", "info"];
    exact(input.theme, roles);
    roles.forEach(function (key) {
      var value = input.theme[key];
      if (typeof value !== "string" || !(key === "border" ? /^#[0-9a-f]{6}([0-9a-f]{2})?$/i : /^#[0-9a-f]{6}$/i).test(value)) throw new Error("Invalid palette");
      var rgb = [1, 3, 5].map(function (offset) { return parseInt(value.slice(offset, offset + 2), 16); }).join(" ");
      if (["success", "warning", "error", "info"].includes(key)) state.style.setProperty("--color-" + key, rgb);
      else state.style.setProperty("--astral-" + key, rgb);
      if (key === "surface2") state.style.setProperty("--surface-2", value);
      if (key === "border") state.style.setProperty("--border-soft", "1px solid " + value);
    });
    var template = document.createElement("template");
    template.innerHTML = input.html;
    var elements = template.content.querySelectorAll("*");
    if (elements.length > 12000) throw new Error("Large canvas");
    elements.forEach(function (node) {
      if (!/^(DIV|SPAN|P|H[1-6]|UL|OL|LI|TABLE|THEAD|TBODY|TFOOT|TR|TH|TD|CAPTION|COLGROUP|COL|DL|DT|DD|PRE|CODE|BLOCKQUOTE|STRONG|EM|B|I|U|S|DEL|BR|HR|A|IMG|DETAILS|SUMMARY|SECTION|ARTICLE|FIGURE|FIGCAPTION|LABEL|SMALL|SUP|SUB)$/.test(node.tagName)) throw new Error("Unsafe markup");
      Array.from(node.attributes).forEach(function (attr) {
        if (!/^(class|style|role|colspan|rowspan|scope|open|start|reversed|dir|lang|alt|width|height|aria-[a-z-]+)$/.test(attr.name) &&
            !(node.tagName === "IMG" && attr.name === "src")) throw new Error("Unsafe attribute");
        if (attr.name === "style" && /url\s*\(|expression|@import/i.test(attr.value)) throw new Error("Unsafe style");
        if (attr.name === "src" && !/^data:image\/png;base64,[A-Za-z0-9+/]+=*$/.test(attr.value)) throw new Error("Missing image pixels");
      });
    });
    var canvas = document.getElementById("astral-canvas");
    canvas.style.width = input.viewport.width + "px";
    // Capture width is the already-inset native content box. Shared mobile
    // canvas CSS must not subtract a second set of gutters from its children.
    canvas.style.padding = "0";
    canvas.appendChild(template.content);
    // The private native document is deliberately detached/hidden. WebKit
    // suspends animation frames there, so settle the bundled Tailwind mutation
    // observer through event-loop turns and force layout before awaiting fonts.
    await new Promise(function (resolve) { setTimeout(resolve, 0); });
    canvas.getBoundingClientRect();
    await document.fonts.ready;
    await new Promise(function (resolve) { setTimeout(resolve, 0); });
    if (Math.abs(canvas.getBoundingClientRect().width - input.viewport.width) > 1) throw new Error("Incorrect canvas width");
    await Promise.all(Array.from(canvas.querySelectorAll("img"), function (node) {
      return node.decode().then(function () {
        if (!node.naturalWidth || !node.naturalHeight || node.naturalWidth > 4096 || node.naturalHeight > 4096) throw new Error("Image unavailable");
      });
    }));
    var blob = await window.AstralCanvasExport.snapshot({
      canvas: canvas,
      loadFont: function (name) {
        var encoded = window.AstralExportFonts[name];
        if (!encoded) throw new Error("Missing font");
        return Uint8Array.from(atob(encoded), function (c) { return c.charCodeAt(0); }).buffer;
      },
    });
    var html = await blob.text();
    if (new TextEncoder().encode(html).byteLength > 32 * 1024 * 1024) throw new Error("Large output");
    if (retired) return;
    window.AstralExportResult = Object.freeze({ state: "ready", html: html });
    state.dataset.exportState = "ready";
    document.getElementById("export-status").remove();
  }
  var timeout;
  Promise.race([
    start(),
    new Promise(function (_resolve, reject) { timeout = setTimeout(function () { reject(new Error("Timeout")); }, 20000); }),
  ]).catch(fail).finally(function () { clearTimeout(timeout); });
})();
