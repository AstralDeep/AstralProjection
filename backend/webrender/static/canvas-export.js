/* Shared script-free visual export finalizer. No identity or action authority. */
(function () {
  "use strict";
  /** Rebuild a mounted canvas using explicit public-font bytes and Plotly pixels. */
  async function snapshot(options) {
    var canvas = options.canvas;
    var document = canvas.ownerDocument;
    var Plotly = options.plotly;
    var getComputedStyle = document.defaultView.getComputedStyle.bind(document.defaultView);
    // Export only the mounted canvas. Chat, credentials, action payloads and
    // author markup are never serialized; all nodes/attributes are rebuilt.
    var doc = document.implementation.createHTMLDocument("AstralDeep workspace");
    var policy = doc.createElement("meta");
    policy.httpEquiv = "Content-Security-Policy";
    policy.content = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; base-uri 'none'; form-action 'none'";
    doc.head.prepend(policy);
    var viewport = doc.createElement("meta");
    viewport.name = "viewport";
    viewport.content = "width=device-width, initial-scale=1";
    doc.head.appendChild(viewport);
    var charset = doc.createElement("meta");
    charset.setAttribute("charset", "utf-8");
    doc.head.prepend(charset);
    var jobs = [], count = 0;
    // Fonts are the same public, first-party-hosted assets the live shell uses.
    // Embed their bytes so opening the file makes no server/network requests.
    [["Inter", "inter-latin.woff2", "400 700"], ["JetBrains Mono", "jetbrains-mono-latin.woff2", "400"]].forEach(function (font) {
      jobs.push(function () { return Promise.resolve(options.loadFont(font[1])).then(function (buffer) {
        if (buffer.byteLength > 1024 * 1024) throw new Error("Canvas font exceeds the export size limit.");
        var bytes = new Uint8Array(buffer), binary = "";
        for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
        var css = doc.createElement("style");
        css.textContent = "@font-face{font-family:'" + font[0] + "';font-style:normal;font-weight:" + font[2] + ";src:url(data:font/woff2;base64," + btoa(binary) + ") format('woff2')}";
        doc.head.appendChild(css);
      }); });
    });
    var allowed = /^(DIV|SPAN|P|H[1-6]|UL|OL|LI|TABLE|THEAD|TBODY|TFOOT|TR|TH|TD|CAPTION|COLGROUP|COL|DL|DT|DD|PRE|CODE|BLOCKQUOTE|STRONG|EM|B|I|U|S|BR|HR|A|IMG|DETAILS|SUMMARY|SECTION|ARTICLE|FIGURE|FIGCAPTION|LABEL|SMALL|SUP|SUB)$/;
    function copyStyle(source, target) {
      var style = getComputedStyle(source);
      for (var i = 0; i < style.length; i++) {
        var key = style[i], value = style.getPropertyValue(key);
        // Computed values capture the selected theme without carrying any
        // stylesheet, custom-property payload, animation or network URL.
        if (key.indexOf("--") === 0 || /^(animation|transition)/.test(key) || /url\s*\(/i.test(value)) continue;
        target.style.setProperty(key, value);
      }
      target.style.animation = "none";
      target.style.transition = "none";
    }
    function copy(node) {
      if (++count > 12000) throw new Error("Canvas is too large to export in one document.");
      if (node.nodeType === Node.TEXT_NODE) return doc.createTextNode(node.textContent);
      if (node.nodeType !== Node.ELEMENT_NODE) return null;
      if (node.matches(".astral-component-chrome,.astral-pagination,.astral-provenance--grounded,.astral-transient-overlay,.astral-skeleton,[data-welcome]")) return null;
      if (node.classList.contains("astral-chart")) {
        if (typeof Plotly === "undefined" || !node.dataset.rendered) throw new Error("Charts are still loading. Try the download again when they appear.");
        var chartImage = doc.createElement("img");
        var rect = node.getBoundingClientRect();
        chartImage.alt = node.getAttribute("aria-label") || "Chart";
        chartImage.style.cssText = "display:block;width:100%;height:auto;max-width:100%";
        jobs.push(function () { return Promise.resolve(node._astralPlotReady).then(function () {
          return Plotly.toImage(node, { format: "png", width: Math.max(1, Math.round(rect.width)), height: Math.max(1, Math.round(rect.height)), scale: 2 });
        }).then(function (url) {
          if (!/^data:image\/png;base64,/.test(url)) throw new Error("Chart export did not produce an image.");
          chartImage.src = url;
        }); });
        return chartImage;
      }
      if (!allowed.test(node.tagName) || getComputedStyle(node).display === "none") return null;
      var out = doc.createElement(node.tagName.toLowerCase());
      copyStyle(node, out);
      Array.from(node.attributes).forEach(function (attr) {
        if (/^(aria-[a-z-]+|role|colspan|rowspan|scope|open|start|reversed|dir|lang)$/.test(attr.name)) out.setAttribute(attr.name, attr.value);
      });
      if (node.tagName === "IMG") {
        out.alt = node.alt || "Image";
        // Copy loaded pixels; never refetch media or retain authenticated URLs.
        var pixels = document.createElement("canvas");
        pixels.width = Math.min(node.naturalWidth || 1, 4096);
        pixels.height = Math.min(node.naturalHeight || 1, 4096);
        try {
          pixels.getContext("2d").drawImage(node, 0, 0, pixels.width, pixels.height);
          out.src = pixels.toDataURL("image/png");
        } catch (e) { throw new Error("An image cannot be copied into this offline download.", { cause: e }); }
      }
      Array.from(node.childNodes).forEach(function (child) { var next = copy(child); if (next) out.appendChild(next); });
      return out;
    }
    copyStyle(document.body, doc.body);
    doc.body.style.cssText += ";margin:0;height:auto;min-height:100vh;overflow:auto;display:block";
    var main = doc.createElement("main");
    copyStyle(canvas, main);
    main.style.cssText += ";height:auto;max-height:none;overflow:visible;margin:0 auto;display:block";
    main.style.width = Math.round(canvas.getBoundingClientRect().width) + "px";
    main.style.maxWidth = "100%";
    Array.from(canvas.children).forEach(function (child) {
      if (!child.matches(".dynamic-renderer,.astral-component")) return;
      var next = copy(child); if (next) main.appendChild(next);
    });
    if (!main.children.length) throw new Error("There is no canvas content to export yet.");
    doc.body.appendChild(main);
    await Promise.all(jobs.map(function (job) { return job(); }));
    var html = "<!DOCTYPE html>" + doc.documentElement.outerHTML;
    if (new TextEncoder().encode(html).byteLength > 32 * 1024 * 1024) throw new Error("Canvas export exceeds the 32 MB document limit.");
    return new Blob([html], { type: "text/html;charset=utf-8" });
  }

  window.AstralCanvasExport = Object.freeze({ snapshot: snapshot });
})();
