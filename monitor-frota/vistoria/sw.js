// Vistoria BDV: guarda o app para abrir sem internet. Chamadas ao Supabase passam direto (a fila offline fica no app).
var CACHE = "vistoria-bdv-v2";
var SHELL = ["./", "index.html", "manifest.webmanifest", "icon-192.png", "icon-512.png"];

self.addEventListener("install", function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) { return c.addAll(SHELL); }).then(function () { return self.skipWaiting(); }));
});
self.addEventListener("activate", function (e) {
  e.waitUntil(caches.keys().then(function (ks) {
    return Promise.all(ks.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});

// Rede primeiro para pegar versao nova, mas com limite de 4 s: sinal fraco no patio nao trava a abertura.
function comLimite(p, ms) {
  return new Promise(function (ok, erro) {
    var t = setTimeout(function () { erro(new Error("tempo")); }, ms);
    p.then(function (r) { clearTimeout(t); ok(r); }, function (x) { clearTimeout(t); erro(x); });
  });
}
self.addEventListener("fetch", function (e) {
  var u = new URL(e.request.url);
  if (e.request.method !== "GET" || u.hostname.indexOf("supabase.co") >= 0) return;
  var fonte = u.hostname.indexOf("fonts.") === 0;
  if (u.origin !== location.origin && !fonte) return;
  var rede = fetch(e.request).then(function (r) {
    if (r.ok || (fonte && r.type === "opaque")) {
      var copy = r.clone(); caches.open(CACHE).then(function (c) { c.put(e.request, copy); });
    }
    return r;
  });
  e.respondWith(comLimite(rede, 4000).catch(function () {
    return caches.match(e.request, { ignoreSearch: true }).then(function (m) {
      return m || (e.request.mode === "navigate" ? caches.match("index.html") : rede);
    });
  }));
});
