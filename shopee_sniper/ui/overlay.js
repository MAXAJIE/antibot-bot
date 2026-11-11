// Phase 7 in-page HUD. Installed at document start, updated from Python.
(() => {
  const el = document.createElement("div");
  el.id = "__hud";
  el.style.cssText = [
    "position:fixed", "right:8px", "bottom:8px", "z-index:2147483647",
    "font:11px/1.35 ui-monospace,monospace", "background:#000c", "color:#ddd",
    "padding:6px 8px", "border-radius:4px", "pointer-events:none",
    "white-space:pre",
  ].join(";");
  const paint = (d) => {
    el.textContent = [
      `bot ${d.bot_id}  ${d.state}`,
      `rtt ${(d.rtt_ms || 0).toFixed(0)}ms  off ${(d.offset_ms || 0).toFixed(0)}ms`,
      `ttl ${(d.ttl_s || 0).toFixed(1)}s  last ${d.last_status || "-"}`,
      d.last_event || "",
    ].join("\n");
  };
  window.__HUD__ = paint;
  const mount = () => {
    if (!document.body) return requestAnimationFrame(mount);
    document.body.appendChild(el);
    paint(window.__HUD_INIT__ || {});
  };
  mount();
})();