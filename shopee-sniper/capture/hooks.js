// Injected at document start. Records header ORDER, not just values.
(() => {
  const sink = (rec) => {
    try { window.__captureSink && window.__captureSink(rec); } catch (_) {}
  };

  const XO = XMLHttpRequest.prototype.open;
  const XS = XMLHttpRequest.prototype.send;
  const XH = XMLHttpRequest.prototype.setRequestHeader;

  XMLHttpRequest.prototype.open = function (m, u, ...rest) {
    this.__rec = { kind: "xhr", method: m, url: u, order: [], headers: {} };
    return XO.call(this, m, u, ...rest);
  };
  XMLHttpRequest.prototype.setRequestHeader = function (k, v) {
    if (this.__rec) { this.__rec.order.push(k); this.__rec.headers[k] = v; }
    return XH.call(this, k, v);
  };
  XMLHttpRequest.prototype.send = function (body) {
    if (this.__rec) { this.__rec.body = body; this.__rec.ts = Date.now(); sink(this.__rec); }
    return XS.call(this, body);
  };

  const F = window.fetch;
  window.fetch = function (input, init) {
    const url = typeof input === "string" ? input : input.url;
    const rec = {
      kind: "fetch", method: (init && init.method) || "GET", url,
      order: [], headers: {}, body: init && init.body, ts: Date.now(),
    };
    const h = (init && init.headers) || {};
    if (h instanceof Headers) h.forEach((v, k) => { rec.order.push(k); rec.headers[k] = v; });
    else Object.entries(h).forEach(([k, v]) => { rec.order.push(k); rec.headers[k] = String(v); });
    sink(rec);
    return F.apply(this, arguments);
  };
})();