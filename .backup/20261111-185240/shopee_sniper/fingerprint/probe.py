"""Collect every surface the gate checks, from inside the page."""
from __future__ import annotations

import json

# Returns a promise; page.evaluate resolves it before handing the value back.
PROBE = r"""
() => {
  const gl = (() => {
    try {
      const c = document.createElement("canvas");
      const g = c.getContext("webgl") || c.getContext("experimental-webgl");
      if (!g) return ["", ""];
      const d = g.getExtension("WEBGL_debug_renderer_info");
      return [
        String(g.getParameter(d ? d.UNMASKED_VENDOR_WEBGL : 0x1F00)),
        String(g.getParameter(d ? d.UNMASKED_RENDERER_WEBGL : 0x1F01)),
      ];
    } catch (e) { return ["", ""]; }
  })();

  const canvas = (() => {
    try {
      const c = document.createElement("canvas");
      c.width = 240; c.height = 60;
      const x = c.getContext("2d");
      x.textBaseline = "top";
      x.font = "14px Arial";
      x.fillStyle = "#f60";
      x.fillRect(0, 0, 120, 20);
      x.fillStyle = "#069";
      x.fillText("Shopee fingerprint 1234", 2, 15);
      return [c.toDataURL(), c.toDataURL()];
    } catch (e) { return ["", ""]; }
  })();

  let permStr = "";
  try {
    permStr = Function.prototype.toString.call(navigator.permissions.query);
  } catch (e) {}

  return (async () => {
    let permIsTarget = false;
    try {
      const r = await navigator.permissions.query({ name: "notifications" });
      permIsTarget = !!r && typeof r.addEventListener === "function";
    } catch (e) {}

    let webglExt = false;
    try {
      const g = document.createElement("canvas").getContext("webgl");
      webglExt = !!g && g.getSupportedExtensions()
        .indexOf("WEBGL_debug_renderer_info") >= 0;
    } catch (e) {}

    return {
      webdriver: navigator.webdriver,
      ua: navigator.userAgent,
      platform: navigator.platform,
      vendor: navigator.vendor,
      cores: navigator.hardwareConcurrency,
      memory: navigator.deviceMemory,
      languages: Array.from(navigator.languages),
      touch: navigator.maxTouchPoints,
      dpr: window.devicePixelRatio,
      screen_w: screen.width,
      screen_h: screen.height,
      avail_h: screen.availHeight,
      inner_w: innerWidth,
      inner_h: innerHeight,
      outer_w: outerWidth,
      outer_h: outerHeight,
      tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
      tz_offset: new Date().getTimezoneOffset(),
      gl_vendor: gl[0],
      gl_renderer: gl[1],
      canvas_a: canvas[0],
      canvas_b: canvas[1],
      plugins: navigator.plugins.length,
      mime_types: navigator.mimeTypes.length,
      chrome_runtime: !!(window.chrome && window.chrome.runtime),
      pdf: navigator.pdfViewerEnabled,
      perm_is_eventtarget: permIsTarget,
      perm_tostring: permStr,
      brands: (navigator.userAgentData && navigator.userAgentData.brands) || [],
      ua_mobile: navigator.userAgentData ? navigator.userAgentData.mobile : null,
      ua_platform: navigator.userAgentData ? navigator.userAgentData.platform : null,
      webgl_ext: webglExt,
    };
  })();
}
"""


async def dump(page) -> dict:
    raw = await page.evaluate(PROBE)
    return json.loads(json.dumps(raw))