// Applied at document start, before any Shopee JS runs.
(() => {
  const CFG = window.__FP__ || {};

  Object.defineProperty(navigator, "webdriver", { get: () => undefined });
  Object.defineProperty(navigator, "platform", { get: () => CFG.platform || "Win32" });
  Object.defineProperty(navigator, "hardwareConcurrency", { get: () => CFG.cores || 8 });
  Object.defineProperty(navigator, "deviceMemory", { get: () => CFG.memory || 8 });
  Object.defineProperty(navigator, "languages", { get: () => CFG.languages || ["en-SG", "en"] });
  Object.defineProperty(navigator, "plugins", {
    get: () => [
      { name: "PDF Viewer" }, { name: "Chrome PDF Viewer" },
      { name: "Chromium PDF Viewer" }, { name: "Microsoft Edge PDF Viewer" },
      { name: "WebKit built-in PDF" },
    ],
  });

  if (!window.chrome) window.chrome = {};
  window.chrome.runtime = window.chrome.runtime || { id: undefined };

  const qp = navigator.permissions.query.bind(navigator.permissions);
  navigator.permissions.query = (p) =>
    p && p.name === "notifications"
      ? Promise.resolve({ state: Notification.permission, onchange: null })
      : qp(p);

  const seed = CFG.canvasSeed || 1;
  let s = seed >>> 0;
  const rnd = () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);
  const toDataURL = HTMLCanvasElement.prototype.toDataURL;
  HTMLCanvasElement.prototype.toDataURL = function (...a) {
    const ctx = this.getContext("2d");
    if (ctx) {
      const img = ctx.getImageData(0, 0, this.width, this.height);
      for (let i = 0; i < img.data.length; i += 4) {
        if (rnd() < 0.02) img.data[i] = (img.data[i] + 1) & 255;
      }
      ctx.putImageData(img, 0, 0);
    }
    return toDataURL.apply(this, a);
  };

  if (window.AudioContext) {
    const orig = AudioContext.prototype.createOscillator;
    AudioContext.prototype.createOscillator = function () {
      const o = orig.call(this);
      o.frequency.value = 10000 + (seed % 97) * 0.01;
      return o;
    };
  }
})();