// Document-start stealth. The config literal is injected immediately before
// this file, so it must never depend on window.__FP__ being set by a later
// script - that was the old bug: the reader ran, the writer never did.
(() => {
  "use strict";
  const C = window.__FP__;
  if (!C) return;

  const def = (obj, prop, getter) => {
    try {
      Object.defineProperty(obj, prop,
        { get: getter, configurable: true, enumerable: true });
    } catch (_) {}
  };

  // Patched natives must still stringify as native.
  const nativeToString = Function.prototype.toString;
  const spoofed = new WeakMap();
  Function.prototype.toString = new Proxy(nativeToString, {
    apply(t, self, a) {
      return spoofed.has(self) ? spoofed.get(self) : t.apply(self, a);
    },
  });
  const mark = (fn, name) => {
    spoofed.set(fn, "function " + name + "() { [native code] }");
    return fn;
  };

  // ---- navigator ---------------------------------------------------------
  const N = Navigator.prototype;
  def(N, "webdriver", () => false);            // real Chrome says false, not undefined
  def(N, "platform", () => C.platform);
  def(N, "vendor", () => "Google Inc.");
  def(N, "vendorSub", () => "");
  def(N, "productSub", () => "20030107");
  def(N, "hardwareConcurrency", () => C.cores);
  def(N, "deviceMemory", () => C.memory);
  def(N, "maxTouchPoints", () => C.touchPoints);
  def(N, "pdfViewerEnabled", () => true);
  def(N, "languages", () => Object.freeze(C.languages.slice()));
  def(N, "language", () => C.languages[0]);

  if (C.uaBrands && C.uaBrands.length) {
    const brands = C.uaBrands.map(([b, v]) => ({ brand: b, version: v }));
    const full = C.uaFullVersions.map(([b, v]) => ({ brand: b, version: v }));
    const uaData = {
      brands,
      mobile: !!C.uaMobile,
      platform: C.uaPlatform,
      getHighEntropyValues: (hints) => {
        const out = { brands, mobile: !!C.uaMobile, platform: C.uaPlatform };
        for (const h of hints || []) {
          if (h === "fullVersionList") out.fullVersionList = full;
          if (h === "architecture") out.architecture = "x86";
          if (h === "bitness") out.bitness = "64";
          if (h === "model") out.model = "";
          if (h === "platformVersion") out.platformVersion = "15.0.0";
          if (h === "wow64") out.wow64 = false;
          if (h === "uaFullVersion") out.uaFullVersion = C.uaFullVersions[2][1];
        }
        return Promise.resolve(out);
      },
      toJSON: () => ({ brands, mobile: !!C.uaMobile, platform: C.uaPlatform }),
    };
    def(N, "userAgentData", () => uaData);
  }

  // ---- plugins / mimeTypes ----------------------------------------------
  const mkMime = (type, suffixes, desc) => ({
    type, suffixes, description: desc, enabledPlugin: null,
  });
  const mkPlugin = (name, filename, desc, mimes) => {
    const p = { name, filename, description: desc, length: mimes.length };
    mimes.forEach((m, i) => { p[i] = m; m.enabledPlugin = p; });
    p.item = (i) => p[i] || null;
    p.namedItem = (n) => mimes.find((m) => m.type === n) || null;
    return p;
  };
  const plugins = [
    mkPlugin("PDF Viewer", "internal-pdf-viewer", "Portable Document Format",
      [mkMime("application/pdf", "pdf", "Portable Document Format"),
       mkMime("text/pdf", "pdf", "Portable Document Format")]),
    mkPlugin("Chrome PDF Viewer", "internal-pdf-viewer", "Portable Document Format",
      [mkMime("application/x-google-chrome-pdf", "pdf", "Portable Document Format")]),
    mkPlugin("Chromium PDF Viewer", "internal-pdf-viewer", "Portable Document Format",
      [mkMime("application/x-google-chrome-pdf", "pdf", "Portable Document Format")]),
    mkPlugin("Microsoft Edge PDF Viewer", "internal-pdf-viewer",
      "Portable Document Format",
      [mkMime("application/x-google-chrome-pdf", "pdf", "Portable Document Format")]),
    mkPlugin("WebKit built-in PDF", "internal-pdf-viewer", "Portable Document Format",
      [mkMime("application/x-google-chrome-pdf", "pdf", "Portable Document Format")]),
  ];
  plugins.item = (i) => plugins[i] || null;
  plugins.namedItem = (n) => plugins.find((p) => p.name === n) || null;
  def(N, "plugins", () => plugins);
  const mimes = plugins.flatMap((p) => [p[0], p[1]].filter(Boolean));
  mimes.item = (i) => mimes[i] || null;
  mimes.namedItem = (n) => mimes.find((m) => m.type === n) || null;
  def(N, "mimeTypes", () => mimes);

  def(N, "connection", () => {
    const c = new EventTarget();
    c.effectiveType = "4g";
    c.rtt = 50;
    c.downlink = 10;
    c.saveData = false;
    c.type = "wifi";
    c.onchange = null;
    return c;
  });

  // ---- chrome.* ----------------------------------------------------------
  window.chrome = window.chrome || {};
  window.chrome.runtime = window.chrome.runtime || {};
  if (!("id" in window.chrome.runtime)) {
    window.chrome.runtime.id = undefined;
    window.chrome.runtime.connect = mark(function connect() {
      throw new Error("Could not establish connection.");
    }, "connect");
    window.chrome.runtime.sendMessage = mark(function sendMessage() {
      throw new Error("Could not establish connection.");
    }, "sendMessage");
  }
  window.chrome.app = window.chrome.app || {
    isInstalled: false,
    InstallState: { DISABLED: "disabled", INSTALLED: "installed", NOT_INSTALLED: "not_installed" },
    RunningState: { CANNOT_RUN: "cannot_run", READY_TO_RUN: "ready_to_run", RUNNING: "running" },
    getDetails: () => null,
    getIsInstalled: () => false,
  };
  window.chrome.csi = window.chrome.csi || (() => ({
    onloadT: performance.timing.domContentLoadedEventEnd,
    startE: performance.timing.navigationStart,
    pageT: performance.now(),
    tran: 15,
  }));
  window.chrome.loadTimes = window.chrome.loadTimes || (() => ({}));

  // ---- permissions -------------------------------------------------------
  // The old shim returned a bare object literal. Code that calls
  // addEventListener on the result throws.
  const pq = navigator.permissions.query.bind(navigator.permissions);
  const permissionStub = (state) => {
    const t = new EventTarget();
    t.state = state;
    t.onchange = null;
    return t;
  };
  navigator.permissions.query = mark(function query(p) {
    if (p && p.name === "notifications") {
      return Promise.resolve(permissionStub(Notification.permission));
    }
    return pq(p);
  }, "query");
  def(Notification, "permission", () => "default");

  // ---- screen / window geometry -----------------------------------------
  const S = Screen.prototype;
  def(S, "width", () => C.screen.width);
  def(S, "height", () => C.screen.height);
  def(S, "availWidth", () => C.screen.width);
  def(S, "availHeight", () => C.screen.availHeight);
  def(S, "colorDepth", () => 24);
  def(S, "pixelDepth", () => 24);
  def(window, "devicePixelRatio", () => C.dpr);
  def(window, "outerWidth", () => C.window.w);
  def(window, "outerHeight", () => C.window.h);

  // ---- WebGL -------------------------------------------------------------
  // In a VM or on a headless host this reports SwiftShader, which contradicts
  // every other surface in the profile.
  const patchGL = (proto) => {
    const gp = proto.getParameter;
    proto.getParameter = mark(new Proxy(gp, {
      apply(t, self, a) {
        const p = a[0];
        if (p === 37445 || p === 7936) return C.gpuVendor;
        if (p === 37446 || p === 7937) return C.gpuRenderer;
        return t.apply(self, a);
      },
    }), "getParameter");
    const ge = proto.getSupportedExtensions;
    proto.getSupportedExtensions = mark(new Proxy(ge, {
      apply(t, self, a) {
        const out = t.apply(self, a) || [];
        return out.indexOf("WEBGL_debug_renderer_info") >= 0
          ? out : out.concat("WEBGL_debug_renderer_info");
      },
    }), "getSupportedExtensions");
  };
  if (window.WebGLRenderingContext) patchGL(WebGLRenderingContext.prototype);
  if (window.WebGL2RenderingContext) patchGL(WebGL2RenderingContext.prototype);

  // ---- canvas ------------------------------------------------------------
  // Perturb ONCE per canvas and cache it. The old version re-perturbed on every
  // toDataURL call, so two reads of the same canvas produced two hashes.
  const prepared = new WeakSet();
  const prepare = (el) => {
    if (prepared.has(el)) return;
    prepared.add(el);
    try {
      const ctx = el.getContext("2d");
      if (!ctx || !el.width || !el.height) return;
      const img = ctx.getImageData(0, 0, el.width, el.height);
      let s = C.canvasSeed >>> 0;
      const rnd = () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);
      for (let i = 0; i < img.data.length; i += 4) {
        if (rnd() < 0.02) img.data[i] = (img.data[i] + 1) & 255;
      }
      ctx.putImageData(img, 0, 0);
    } catch (_) {}   // tainted canvas
  };
  const toDataURL = HTMLCanvasElement.prototype.toDataURL;
  HTMLCanvasElement.prototype.toDataURL = mark(function (...a) {
    prepare(this);
    return toDataURL.apply(this, a);
  }, "toDataURL");
  const toBlob = HTMLCanvasElement.prototype.toBlob;
  HTMLCanvasElement.prototype.toBlob = mark(function (...a) {
    prepare(this);
    return toBlob.apply(this, a);
  }, "toBlob");

  // ---- audio -------------------------------------------------------------
  if (window.AudioContext) {
    const createOsc = AudioContext.prototype.createOscillator;
    AudioContext.prototype.createOscillator = mark(function (...a) {
      const o = createOsc.apply(this, a);
      try { o.frequency.value = 10000 + (C.audioSeed % 97) * 0.01; } catch (_) {}
      return o;
    }, "createOscillator");
    const getData = AudioBuffer.prototype.getChannelData;
    AudioBuffer.prototype.getChannelData = mark(function (...a) {
      const d = getData.apply(this, a);
      if (!this.__seeded) {
        this.__seeded = true;
        let h = C.audioSeed >>> 0;
        for (let i = 0; i < d.length; i += 97) {
          h = (h * 1103515245 + 12345) >>> 0;
          d[i] += (h % 1000) / 1e8;
        }
      }
      return d;
    }, "getChannelData");
  }

  // ---- timezone ----------------------------------------------------------
  // Only when the profile timezone differs from the host, otherwise the real
  // value is already correct and the patch is pure risk.
  if (C.timezone && C.timezone !== Intl.DateTimeFormat().resolvedOptions().timeZone) {
    const resolved = Intl.DateTimeFormat.prototype.resolvedOptions;
    Intl.DateTimeFormat.prototype.resolvedOptions = mark(function (...a) {
      const o = resolved.apply(this, a);
      o.timeZone = C.timezone;
      return o;
    }, "resolvedOptions");
  }
})();