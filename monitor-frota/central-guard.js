/* Controle de acessos da Central TFleet (senha pessoal + ver/editar por painel).
   Carregado pelo central-voltar.js em todos os painéis e direto pela central.html.
   SQL: servidor-tvbox/codigos/central-acessos.sql (tabelas central_*, funções acesso_*).

   O que faz em cada painel, quando a pessoa entrou na Central com a senha pessoal:
   - confere a sessão no Supabase e registra que abriu o painel (histórico de acessos);
   - sem permissão no painel: cobre a tela com aviso e botão para a Central;
   - manda o token em toda gravação (cabeçalho x-tf-sessao): o Supabase registra quem editou
     e o que mudou, e recusa a gravação de quem só pode ver; aqui na tela já barra antes;
   - esconde abas/botões que a pessoa não pode usar e dispensa o código 8015 do painel.
   Sem sessão pessoal tudo continua como antes (código 8015), a não ser que a Gestão tenha
   ligado "exigir senha pessoal": aí o painel pede para entrar pela Central.
   Páginas abertas por link de e-mail (roteador-tratativa, resposta) ficam de fora. */
(function () {
  if (window.TFAcesso) return;
  var SB = "https://orhuxmsrdnugpogvtnbg.supabase.co";
  var KEY = "sb_publishable_Hu4Ns0jDTesWzDmVseAl_Q_ubCJa5wL";
  var K = "tf_sessao";
  var PAINEIS = [
    ["monitor", "Monitor Frota"], ["vistoria", "Vistorias"], ["ocorrencias", "Ocorrências"],
    ["lotacao", "Lotação"], ["otimizacao", "Otimização de rotas"], ["roteador", "Roteador"]];
  var nativeFetch = window.fetch.bind(window);

  function ler() { try { return JSON.parse(localStorage.getItem(K) || "null"); } catch (e) { return null; } }
  function gravar(s) { try { localStorage.setItem(K, JSON.stringify(s)); } catch (e) {} }
  function limpar() { try { localStorage.removeItem(K); } catch (e) {} }
  function pode(s, painel, nivel) {
    if (!s) return false;
    if (s.admin) return true;
    var p = (s.perms && s.perms[painel]) || [];
    return nivel === "editar" ? p.indexOf("editar") >= 0 : (p.indexOf("ver") >= 0 || p.indexOf("editar") >= 0);
  }
  function rpc(fn, body) {
    return nativeFetch(SB + "/rest/v1/rpc/" + fn, { method: "POST",
      headers: { apikey: KEY, Authorization: "Bearer " + KEY, "Content-Type": "application/json" },
      body: JSON.stringify(body || {}) }).then(function (r) {
      return r.text().then(function (t) {
        var j = null; try { j = t ? JSON.parse(t) : null; } catch (e) {}
        if (!r.ok) { var err = new Error((j && (j.message || j.hint)) || t || ("erro " + r.status)); err.status = r.status; throw err; }
        return j;
      });
    });
  }
  window.TFAcesso = { SB: SB, KEY: KEY, PAINEIS: PAINEIS, ler: ler, gravar: gravar, limpar: limpar, pode: pode, rpc: rpc };

  // ---------------------------------------------------------------- qual painel é esta página
  var path = (location.pathname || "").toLowerCase();
  if (/central\.html$/.test(path)) return;                                // a Central cuida de si
  if (/(roteador-tratativa|resposta|teste)\.html$/.test(path)) return;    // links de e-mail
  var pagina, paineis;
  if (/\/vistoria(\/|\/index\.html)?$/.test(path) || /\/vistoria\//.test(path)) { pagina = "vistoria"; paineis = ["vistoria", "ocorrencias"]; }
  else if (/lotacao\.html$/.test(path)) { pagina = "lotacao"; paineis = ["lotacao", "otimizacao"]; }
  else if (/roteador\.html$/.test(path)) { pagina = "roteador"; paineis = ["roteador"]; }
  else if (/(\/|index\.html)$/.test(path)) { pagina = "monitor"; paineis = ["monitor"]; }
  else return;
  var prefixo = pagina === "vistoria" ? "../" : "";

  // Quem pode gravar em cada tabela (tem que bater com os gatilhos do SQL)
  var TABELA = { vistorias: ["vistoria"], vistoria_rascunhos: ["vistoria"], ocorrencias: ["ocorrencias", "vistoria"],
    relatores: ["ocorrencias"], device_config: ["monitor"] };
  var RPC_GRAVA = /^(marcar_rota|salvar_|remover_|importar_|definir_)/;

  var sess = ler();
  var semCabecalho = false;   // se o navegador recusar o cabeçalho extra, segue sem ele

  // ---------------------------------------------------------------- gravações com o token
  function paineisDaGravacao(url) {
    var m = /\/rest\/v1\/rpc\/([a-z0-9_]+)/i.exec(url);
    if (m) return RPC_GRAVA.test(m[1]) ? (pagina === "lotacao" ? ["lotacao", "otimizacao"] : null) : null;
    if (/\/storage\/v1\/object\//.test(url)) return pagina === "vistoria" ? ["vistoria"] : null;
    m = /\/rest\/v1\/([a-z0-9_]+)/i.exec(url);
    return m ? (TABELA[m[1]] || null) : null;
  }
  window.fetch = function (input, init) {
    var url = typeof input === "string" ? input : (input && input.url) || String(input || "");
    if (!sess || url.indexOf(SB) !== 0) return nativeFetch(input, init);
    init = Object.assign({}, init || {});
    var metodo = String(init.method || (input && input.method) || "GET").toUpperCase();
    if (metodo !== "GET" && metodo !== "HEAD") {
      var ps = paineisDaGravacao(url);
      if (ps && !ps.some(function (p) { return pode(sess, p, "editar"); })) {
        avisar("Seu acesso é só para ver. Nada foi gravado.");
        return Promise.resolve(new Response(JSON.stringify({ message: "Seu acesso é só para ver." }),
          { status: 403, headers: { "Content-Type": "application/json" } }));
      }
    }
    if (semCabecalho) return nativeFetch(input, init);
    var h = new Headers(init.headers || (input && input.headers) || undefined);
    h.set("x-tf-sessao", sess.token);
    var comToken = Object.assign({}, init, { headers: h });
    return nativeFetch(input, comToken).catch(function (err) {
      if (!navigator.onLine) throw err;
      semCabecalho = true;                 // provável bloqueio de CORS ao cabeçalho: tenta sem
      return nativeFetch(input, init);
    });
  };

  // ---------------------------------------------------------------- interface
  function avisar(msg) {
    if (typeof window.toast === "function") { try { window.toast(msg); return; } catch (e) {} }
    var t = document.getElementById("tf-acesso-aviso");
    if (!t) {
      t = document.createElement("div"); t.id = "tf-acesso-aviso";
      t.style.cssText = "position:fixed;left:50%;bottom:24px;transform:translateX(-50%);z-index:2147483600;background:#0f172a;color:#fff;" +
        "padding:10px 16px;border-radius:10px;font:600 14px system-ui,sans-serif;box-shadow:0 6px 20px rgba(0,0,0,.35);max-width:90vw";
      document.body.appendChild(t);
    }
    t.textContent = msg; t.hidden = false;
    clearTimeout(avisar._t); avisar._t = setTimeout(function () { t.hidden = true; }, 3500);
  }
  function bloquear(titulo, texto) {
    document.querySelectorAll("dialog[open]").forEach(function (d) { try { d.close(); } catch (e) {} });
    var o = document.getElementById("tf-acesso-bloqueio");
    if (!o) { o = document.createElement("div"); o.id = "tf-acesso-bloqueio"; document.body.appendChild(o); }
    o.style.cssText = "position:fixed;inset:0;z-index:2147483500;background:#0b1120;color:#e8edf6;display:flex;" +
      "align-items:center;justify-content:center;padding:16px;font:15px/1.5 system-ui,-apple-system,'Segoe UI',Roboto,sans-serif";
    o.innerHTML = '<div style="max-width:380px;text-align:center"><div style="font-size:40px">🔒</div>' +
      '<h1 style="font-size:20px;margin:8px 0">' + titulo + '</h1><p style="color:#94a3b8;margin:0 0 18px">' + texto + '</p>' +
      '<a href="' + prefixo + 'central.html" style="display:inline-block;background:#2563eb;color:#fff;text-decoration:none;' +
      'padding:12px 22px;border-radius:10px;font-weight:700">Ir para a Central</a></div>';
    document.documentElement.style.overflow = "hidden";
  }
  function selo(s, editar) {
    var b = document.getElementById("tf-acesso-selo");
    if (!b) { b = document.createElement("div"); b.id = "tf-acesso-selo"; document.body.appendChild(b); }
    b.style.cssText = "position:fixed;right:10px;bottom:10px;z-index:2147483000;background:rgba(15,23,42,.85);color:#fff;" +
      "font:600 12px system-ui,sans-serif;padding:5px 10px;border-radius:999px;pointer-events:none;max-width:70vw;" +
      "white-space:nowrap;overflow:hidden;text-overflow:ellipsis";
    b.textContent = "👤 " + String(s.nome || "").split(" ")[0] + (editar ? "" : " · só ver");
  }
  function css(id, txt) {
    var st = document.getElementById(id);
    if (!st) { st = document.createElement("style"); st.id = id; document.head.appendChild(st); }
    st.textContent = txt;
  }

  // ---------------------------------------------------------------- ajustes por painel
  // Usam nomes do código de cada painel (index.html, vistoria/index.html, lotacao.html).
  // Se um painel mudar esses nomes, o ajuste deixa de valer mas o painel continua abrindo.
  function ajustarMonitor(s) {
    try { if (typeof unlocked !== "undefined" && !unlocked) {   // dispensa o 8015 do Monitor
      unlocked = true; var d = document.getElementById("dlgLogin"); if (d && d.open) d.close();
      if (typeof init === "function") init(); } } catch (e) {}
    css("tf-acesso-css", pode(s, "monitor", "editar") ? "" :
      "#btnConfig,#cbSave,#gSave,#eSave{display:none!important}");
  }

  var trocaOrig = null;
  function ajustarVistoria(s) {
    var vV = pode(s, "vistoria", "ver") && ((s.perms && (s.perms.vistoria || []).indexOf("ver") >= 0) || s.admin);
    var vE = pode(s, "vistoria", "editar"), oV = pode(s, "ocorrencias", "ver"), oE = pode(s, "ocorrencias", "editar");
    var ok = [];
    if (vE) ok.push("nova");
    if (vV) ok.push("carros", "dash");
    if (oV) ok.push("oc");
    if (vE) ok.push("enviadas");
    if (!ok.length) return;
    document.querySelectorAll("#tabs button[data-view]").forEach(function (b) { b.hidden = ok.indexOf(b.dataset.view) < 0; });
    if (typeof window.switchView === "function") {
      if (!trocaOrig) trocaOrig = window.switchView;
      window.switchView = function (v) { return trocaOrig(ok.indexOf(v) >= 0 ? v : ok[0]); };
      try { if (typeof view !== "undefined" && ok.indexOf(view) < 0) window.switchView(ok[0]); } catch (e) {}
    }
    if (!vE) css("tf-acesso-css", "#savebar{display:none!important}");
    if (!oE && typeof window.patchOc === "function" && !window.patchOc.tf) {
      var f = function () { avisar("Seu acesso às ocorrências é só para ver."); }; f.tf = true; window.patchOc = f;
    }
  }

  function ajustarLotacao(s) {
    var lV = pode(s, "lotacao", "ver"), lE = pode(s, "lotacao", "editar");
    var tV = pode(s, "otimizacao", "ver"), tE = pode(s, "otimizacao", "editar");
    try { var g = document.getElementById("gate");                         // dispensa o 8015 da Lotação
      if (g) { try { sessionStorage.setItem("lot_ok", "1"); } catch (e) {}
        g.remove(); if (typeof load === "function") load(); if (typeof abaIni === "function") abaIni(); } } catch (e) {}
    var ok = [];
    if (lV || lE) ok.push("ocup", "fora");
    if (lE) ok.push("cad", "resp");
    if (tV) ok.push("otim");
    var tabs = document.querySelectorAll(".tabs button[data-tab]");
    tabs.forEach(function (b) { b.hidden = ok.indexOf(b.dataset.tab) < 0; });
    var on = document.querySelector(".tabs button[data-tab].on");
    if (on && on.hidden) { var p = document.querySelector('.tabs button[data-tab]:not([hidden])'); if (p) p.click(); }
    if (lE || tE) {                                   // o token vale como senha de gestores
      try {
        var inp = document.getElementById("gSenha"); if (inp) inp.value = s.token;
        if (typeof gSenha !== "undefined" && gSenha !== s.token) {
          gSenha = s.token;
          if (typeof gestCarregado !== "undefined" && gestCarregado && typeof gestLoad === "function") gestLoad();
        }
      } catch (e) {}
    }
    css("tf-acesso-css", "#senhaBar{display:none!important}");   // quem só vê não precisa da senha
  }

  function aplicar(s) {
    var algum = paineis.some(function (p) { return pode(s, p, "ver"); });
    if (!algum) {
      bloquear("Sem acesso a este painel", "Olá, " + esc(String(s.nome || "").split(" ")[0]) +
        ". Sua senha não libera este painel. Fale com o administrador ou volte para a Central.");
      return;
    }
    var editar = paineis.some(function (p) { return pode(s, p, "editar"); });
    selo(s, editar);
    if (pagina === "monitor") ajustarMonitor(s);
    else if (pagina === "vistoria") ajustarVistoria(s);
    else if (pagina === "lotacao") ajustarLotacao(s);
  }
  function esc(t) { return String(t).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }

  function painelDoLog() {
    var h = (location.hash || "").toLowerCase();
    if (pagina === "vistoria") return h === "#ocorrencias" || !pode(sess, "vistoria", "ver") ? "ocorrencias" : "vistoria";
    if (pagina === "lotacao") return h === "#otim" || !pode(sess, "lotacao", "ver") ? "otimizacao" : "lotacao";
    return paineis[0];
  }

  function comecar() {
    if (sess && sess.token) {
      aplicar(sess);                                  // com o que está guardado (funciona offline)
      rpc("acesso_painel", { p_token: sess.token, p_painel: painelDoLog(), p_pagina: path.split("/").pop() || pagina })
        .then(function (r) {
          if (!r || r.erro) { limpar(); sess = null; location.reload(); return; }   // sessão vencida/removida
          sess.nome = r.nome; sess.perms = r.perms || {}; sess.admin = !!r.admin; gravar(sess);
          aplicar(sess);
        })
        .catch(function () { /* sem internet ou SQL ainda não rodado: segue com o guardado */ });
    } else {
      rpc("acesso_config", {}).then(function (c) {
        if (c && c.exigir) bloquear("Entre pela Central", "Este painel agora abre só com a sua senha pessoal. Entre pela Central.");
      }).catch(function () {});
    }
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", comecar);
  else comecar();
})();
