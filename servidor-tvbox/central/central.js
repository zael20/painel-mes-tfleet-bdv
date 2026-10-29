/* Central da Frota: pagina do Cockpit que reune fluxos do n8n, WhatsApp, conexoes, manutencao e terminal.
   Tudo roda pelo comando /usr/local/bin/servidor (com acesso administrativo do Cockpit). */
(function () {
  "use strict";

  var BASE = "/opt/servidor";
  var SERVIDOR = "/usr/local/bin/servidor";
  var PASTAS = [
    { id: "codigos", nome: "Códigos", caminho: BASE + "/codigos", editavel: true,
      dica: "Códigos e anotações do servidor, organizados em pastas." },
    { id: "importar", nome: "Fluxos para importar", caminho: BASE + "/importar", editavel: true,
      dica: "Arquivos .json enviados pelo botão Importar. Os já importados ganham o final .importado." },
    { id: "backups", nome: "Backups", caminho: BASE + "/backups", editavel: false,
      dica: "Cópias diárias dos fluxos e credenciais (criptografadas). Baixe uma de vez em quando para o PC." },
    { id: "config", nome: "Configuração", caminho: BASE, editavel: true, raiz: true,
      dica: "Arquivos de configuração do servidor. Um erro aqui pode parar tudo: depois de salvar, reinicie o programa." }
  ];
  var SEGREDO = /token|senha|password|secret|key|chave|apikey/i;
  var pastaAtual = PASTAS[0];
  var subpasta = "";
  var editando = null;
  var fluxoAberto = null;

  var $ = function (id) { return document.getElementById(id); };
  function el(tag, attrs, filhos) {
    var e = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (k) {
      if (k === "texto") e.textContent = attrs[k];
      else if (k === "classe") e.className = attrs[k];
      else if (k === "valor") e.value = attrs[k];
      else if (k.indexOf("on") === 0) e.addEventListener(k.slice(2), attrs[k]);
      else e.setAttribute(k, attrs[k]);
    });
    (filhos || []).forEach(function (f) { if (f) e.appendChild(typeof f === "string" ? document.createTextNode(f) : f); });
    return e;
  }
  function limpar(no) { no.textContent = ""; return no; }
  function host() {
    try { return window.top.location.hostname; } catch (e) { return window.location.hostname; }
  }
  function linkN8n(caminho) { return "http://" + host() + ":5678" + (caminho || ""); }
  function formatarNumero(n) {
    var m = String(n || "").match(/^55(\d{2})(\d{4,5})(\d{4})$/);
    return m ? "+55 " + m[1] + " " + m[2] + "-" + m[3] : (n || "—");
  }

  /* ---------- execucao de comandos ---------- */
  function saida(txt, anexar) {
    var s = $("saida");
    s.textContent = anexar ? s.textContent + txt : txt;
    s.scrollTop = s.scrollHeight;
  }
  function rodar(args, opts) {
    opts = opts || {};
    return cockpit.spawn(args, { superuser: "require", err: opts.silencioso ? "ignore" : "out" }).then(function (out) {
      if (!opts.silencioso) saida(out || "(concluído sem mensagens)");
      return out;
    }, function (ex) {
      if (!opts.silencioso) saida("ERRO: " + (ex.message || ex) + "\n" + (ex.problem === "access-denied"
        ? "Clique em 'Limited access' no canto superior direito e ative o acesso administrativo." : ""));
      throw ex;
    });
  }
  function rodarComBotao(botao, args, titulo) {
    if (botao) botao.disabled = true;
    saida("▶ " + titulo + "...\n");
    var proc = cockpit.spawn(args, { superuser: "require", err: "out" });
    proc.stream(function (d) { saida(d, true); });
    return proc.then(function () { saida("\n✔ " + titulo + ": concluído.\n", true); },
      function (ex) { saida("\n✖ " + titulo + ": " + (ex.message || ex) + "\n", true); })
      .then(function () { if (botao) botao.disabled = false; atualizarTudo(); });
  }
  function json(args) { return rodar(args, { silencioso: true }).then(function (t) { return JSON.parse(t); }); }

  /* ---------- resumo do topo e programas ---------- */
  function carregarStatus() {
    return json([SERVIDOR, "status-json"]).then(function (s) {
      var livrePct = Math.round(100 * s.ram_livre_mb / s.ram_total_mb);
      var discoPct = Math.round(100 * s.disco_usado_gb / s.disco_total_gb);
      var chips = [
        ["RAM livre " + s.ram_livre_mb + " de " + s.ram_total_mb + " MB", livrePct < 15 ? "erro" : livrePct < 30 ? "atencao" : "ok"],
        ["Cartão " + s.disco_usado_gb + " de " + s.disco_total_gb + " GB", discoPct > 90 ? "erro" : discoPct > 75 ? "atencao" : "ok"],
        ["Temperatura " + s.temp_c + " °C", s.temp_c > 80 ? "erro" : s.temp_c > 70 ? "atencao" : "ok"],
        [s.ultimo_backup ? "Último backup: " + s.ultimo_backup.replace("backup-", "").replace(".tar.gz", "").replace("_", " ") : "Sem backup ainda", s.ultimo_backup ? "" : "atencao"]
      ];
      var r = limpar($("resumo"));
      chips.forEach(function (c) { r.appendChild(el("span", { classe: "chip " + c[1], texto: c[0] })); });

      var nomes = { n8n: "n8n (fluxos)", evolution: "Evolution (WhatsApp)", postgres: "Banco da Evolution", redis: "Cache da Evolution" };
      var box = limpar($("servicos"));
      if (!s.servicos.length) box.appendChild(el("p", { classe: "vazio", texto: "Nenhum programa encontrado. O instalador rodou até o fim?" }));
      s.servicos.forEach(function (sv) {
        var ok = sv.estado === "running";
        box.appendChild(el("div", { classe: "item" }, [
          el("div", {}, [el("div", { classe: "nome" }, [el("span", { classe: "ponto " + (ok ? "ok" : "erro") }), nomes[sv.nome] || sv.nome]),
            el("div", { classe: "info", texto: sv.detalhe })]),
          el("div", { classe: "direita" }, [
            el("button", { classe: "btn mini", texto: "Logs", onclick: function () { rodar([SERVIDOR, "logs", sv.nome, "80"]); } }),
            el("button", { classe: "btn mini", texto: "Reiniciar", onclick: function (ev) { rodarComBotao(ev.target, [SERVIDOR, "reiniciar", sv.nome], "Reiniciar " + sv.nome); } })
          ])
        ]));
      });
    }).catch(function () {
      limpar($("resumo")).appendChild(el("span", { classe: "chip erro", texto: "Sem acesso ao status" }));
    });
  }

  /* ---------- fluxos ---------- */
  function carregarFluxos() {
    return json([SERVIDOR, "fluxos-json"]).then(function (lista) {
      var box = limpar($("fluxos"));
      if (!lista.length) {
        box.appendChild(el("p", { classe: "vazio", texto: "Nenhum fluxo ainda. Abra o n8n uma vez (para criar o usuário dono) e use Importar fluxo." }));
        return;
      }
      lista.forEach(function (f) {
        box.appendChild(el("div", { classe: "item" }, [
          el("div", {}, [el("div", { classe: "nome" }, [el("span", { classe: "ponto " + (f.ativo ? "ok" : "") }), f.nome]),
            el("div", { classe: "info", texto: f.ativo ? "Ligado, roda sozinho" : "Desligado" })]),
          el("div", { classe: "direita" }, [
            el("button", { classe: "btn mini primario", texto: "Configurar", onclick: function () { abrirConfigFluxo(f); } }),
            el("a", { classe: "btn mini", texto: "Editor visual", href: linkN8n("/workflow/" + f.id), target: "_blank", rel: "noopener" }),
            el("button", { classe: "btn mini", texto: f.ativo ? "Desligar" : "Ligar", onclick: function (ev) {
              rodarComBotao(ev.target, [SERVIDOR, f.ativo ? "fluxo-desligar" : "fluxo-ligar", f.id], (f.ativo ? "Desligar " : "Ligar ") + f.nome);
            } })
          ])
        ]));
      });
    }).catch(function () {
      limpar($("fluxos")).appendChild(el("p", { classe: "vazio", texto: "Não consegui ler os fluxos (o n8n está ligado?)." }));
    });
  }
  function importarFluxos(arquivos) {
    var nomes = [];
    var tarefas = Array.prototype.map.call(arquivos, function (a) {
      return a.text().then(function (txt) {
        try { JSON.parse(txt); } catch (e) { throw new Error(a.name + " não é um JSON válido"); }
        var nome = a.name.replace(/[^\w.\- ]+/g, "_");
        nomes.push(nome);
        return cockpit.file(BASE + "/importar/" + nome, { superuser: "require" }).replace(txt);
      });
    });
    saida("▶ Enviando " + arquivos.length + " arquivo(s)...\n");
    Promise.all(tarefas).then(function () {
      saida("Enviados: " + nomes.join(", ") + "\n", true);
      return rodarComBotao(null, [SERVIDOR, "importar"], "Importar no n8n");
    }).catch(function (e) { saida("✖ " + (e.message || e) + "\n", true); });
  }

  /* ---------- configurar fluxo (blocos editaveis) ---------- */
  var TIPOS_HORARIO = [["minutes", "A cada X minutos"], ["hours", "A cada X horas"], ["days", "Todo dia no horário"], ["cronExpression", "Expressão cron (avançado)"]];
  function campoHorario(regra) {
    var tipo = el("select", {}, TIPOS_HORARIO.map(function (t) { return el("option", { value: t[0], texto: t[1] }); }));
    tipo.value = regra.field || "days";
    var num = el("input", { type: "number", min: "1", step: "1" });
    var hora = el("input", { type: "time" });
    var cron = el("input", { type: "text", placeholder: "ex.: 0 19 * * *" });
    num.value = regra.minutesInterval || regra.hoursInterval || 1;
    hora.value = String(regra.triggerAtHour || 0).padStart(2, "0") + ":" + String(regra.triggerAtMinute || 0).padStart(2, "0");
    cron.value = regra.expression || "";
    function mostrar() {
      num.hidden = ["minutes", "hours"].indexOf(tipo.value) < 0;
      hora.hidden = tipo.value !== "days";
      cron.hidden = tipo.value !== "cronExpression";
    }
    tipo.addEventListener("change", mostrar); mostrar();
    return { no: el("div", { classe: "cf-linha" }, [tipo, num, hora, cron]), ler: function () {
      var r = { field: tipo.value };
      if (tipo.value === "minutes") r.minutesInterval = Math.max(1, parseInt(num.value, 10) || 1);
      if (tipo.value === "hours") r.hoursInterval = Math.max(1, parseInt(num.value, 10) || 1);
      if (tipo.value === "days") { var p = (hora.value || "00:00").split(":"); r.daysInterval = 1; r.triggerAtHour = +p[0]; r.triggerAtMinute = +p[1]; }
      if (tipo.value === "cronExpression") r.expression = cron.value.trim();
      return r;
    } };
  }
  function abrirConfigFluxo(f) {
    var corpo = limpar($("cf-corpo"));
    corpo.appendChild(el("p", { classe: "vazio", texto: "carregando o fluxo (alguns segundos)..." }));
    $("cf-titulo").textContent = f.nome;
    $("cf-visual").href = linkN8n("/workflow/" + f.id);
    $("cf-json").value = "";
    $("config-fluxo").showModal();
    rodar([SERVIDOR, "fluxo-exportar", f.id], { silencioso: true }).then(function (txt) {
      var wf = JSON.parse(txt);
      if (Array.isArray(wf)) wf = wf[0];
      fluxoAberto = { id: f.id, wf: wf, leitores: [], jsonOriginal: JSON.stringify(wf, null, 2) };
      $("cf-json").value = fluxoAberto.jsonOriginal;
      montarBlocos(wf);
    }).catch(function (e) {
      limpar(corpo).appendChild(el("p", { classe: "alerta", texto: "Não consegui abrir o fluxo: " + (e.message || e) }));
    });
  }
  function montarBlocos(wf) {
    var corpo = limpar($("cf-corpo"));
    var leitores = fluxoAberto.leitores;
    var nome = el("input", { type: "text", valor: wf.name || "" });
    corpo.appendChild(el("div", { classe: "cf-bloco" }, [el("h3", { texto: "Nome do fluxo" }),
      el("p", { classe: "dica", texto: "Como ele aparece na lista. Use um nome que diga o que ele faz (ex.: Lotação — Coleta)." }),
      el("div", { classe: "cf-campos" }, [el("label", { texto: "Nome" }), nome])]));
    leitores.push(function () { if (nome.value.trim()) wf.name = nome.value.trim(); });
    (wf.nodes || []).forEach(function (no) {
      var p = no.parameters || {};
      if (no.type === "n8n-nodes-base.scheduleTrigger") {
        var regras = (p.rule && p.rule.interval) || [{}];
        var campos = regras.map(campoHorario);
        corpo.appendChild(el("div", { classe: "cf-bloco" }, [el("h3", { texto: "Quando roda · " + no.name }),
          el("p", { classe: "dica", texto: "Horário de Belém. Para rodar uma vez por dia, escolha \"Todo dia no horário\"." })]
          .concat(campos.map(function (c) { return c.no; }))));
        leitores.push(function () { no.parameters.rule = { interval: campos.map(function (c) { return c.ler(); }) }; });
      } else if (no.type === "n8n-nodes-base.set" && p.assignments && Array.isArray(p.assignments.assignments)) {
        var grade = el("div", { classe: "cf-campos" });
        var entradas = p.assignments.assignments.map(function (a) {
          var secreto = SEGREDO.test(a.name);
          var inp = a.type === "boolean"
            ? el("select", {}, [el("option", { value: "true", texto: "sim" }), el("option", { value: "false", texto: "não" })])
            : el("input", { type: secreto ? "password" : a.type === "number" ? "number" : "text" });
          inp.value = String(a.value === undefined || a.value === null ? "" : a.value);
          grade.appendChild(el("label", { texto: a.name + (secreto ? " (secreto)" : "") }));
          grade.appendChild(inp);
          return { a: a, inp: inp };
        });
        corpo.appendChild(el("div", { classe: "cf-bloco" }, [el("h3", { texto: "Configurações · " + no.name }),
          el("p", { classe: "dica", texto: "E-mails, limites e chaves que o fluxo usa. Campos secretos aparecem escondidos." }), grade]));
        leitores.push(function () {
          entradas.forEach(function (e) {
            var v = e.inp.value;
            e.a.value = e.a.type === "number" ? (v === "" ? 0 : Number(v)) : e.a.type === "boolean" ? v === "true" : v;
          });
        });
      } else if (no.type === "n8n-nodes-base.code" && typeof p.jsCode === "string") {
        var area = el("textarea", { classe: "cf-codigo", spellcheck: "false" });
        area.value = p.jsCode;
        corpo.appendChild(el("div", { classe: "cf-bloco" }, [el("h3", { texto: "Código · " + no.name }),
          el("p", { classe: "dica", texto: "Quando eu te mandar um código novo para este bloco: apague tudo aqui, cole o novo e salve." }), area]));
        leitores.push(function () { no.parameters.jsCode = area.value; });
      }
    });
    if (!leitores.length) corpo.appendChild(el("p", { classe: "vazio", texto: "Este fluxo não tem blocos simples para editar aqui. Use o editor visual." }));
  }
  function salvarConfigFluxo(ev) {
    ev.preventDefault();
    if (!fluxoAberto) return;
    var wf;
    try {
      var txt = $("cf-json").value;
      if (txt.trim() !== fluxoAberto.jsonOriginal.trim()) wf = JSON.parse(txt);
      else { fluxoAberto.leitores.forEach(function (l) { l(); }); wf = fluxoAberto.wf; }
    } catch (e) { alert("O JSON tem erro e nada foi salvo:\n" + e.message); return; }
    var id = fluxoAberto.id;
    cockpit.file(BASE + "/importar/.editar-" + id + ".json", { superuser: "require" }).replace(JSON.stringify([wf], null, 2))
      .then(function () {
        $("config-fluxo").close();
        rodarComBotao(null, [SERVIDOR, "fluxo-salvar", id], "Salvar fluxo " + (wf.name || id));
      }).catch(function (e) { alert("Não salvou: " + (e.message || e)); });
  }

  /* ---------- whatsapp ---------- */
  function carregarWhatsapp() {
    return json([SERVIDOR, "whatsapp-json"]).then(function (w) {
      $("wa-esperado").textContent = formatarNumero(w.esperado);
      var box = limpar($("whatsapp"));
      if (!w.ok) { box.appendChild(el("p", { classe: "vazio", texto: "A Evolution não respondeu." })); return; }
      if (!w.instancias.length) {
        box.appendChild(el("p", { classe: "vazio", texto: "Nenhum número conectado ainda. Abra a tela do QR e crie a instância." }));
        return;
      }
      w.instancias.forEach(function (i) {
        var on = i.estado === "open";
        var outro = on && w.esperado && i.numero && i.numero !== w.esperado;
        box.appendChild(el("div", { classe: "item" }, [
          el("div", {}, [el("div", { classe: "nome" }, [el("span", { classe: "ponto " + (on ? (outro ? "atencao" : "ok") : "erro") }), i.nome]),
            el("div", { classe: "info", texto: formatarNumero(i.numero) + (outro ? " · não é o número do servidor" : "") })]),
          el("span", { classe: "chip " + (on ? "ok" : "erro"), texto: on ? "conectado" : "desconectado" })
        ]));
      });
    }).catch(function () {});
  }

  /* ---------- conexoes ---------- */
  function cartao(ok, nome, texto, botoes) {
    return el("div", { classe: "check " + (ok === true ? "ok" : ok === false ? "erro" : "") }, [
      el("div", { classe: "nome" }, [el("span", { classe: "ponto " + (ok === true ? "ok" : ok === false ? "erro" : "") }), nome]),
      el("div", { classe: "info", texto: texto })
    ].concat(botoes && botoes.length ? [el("div", { classe: "acoes" }, botoes)] : []));
  }
  function carregarRede() {
    return json([SERVIDOR, "rede-json"]).then(function (r) {
      var box = limpar($("rede"));
      box.appendChild(cartao(r.cabo.ok, "Cabo de rede", r.cabo.ok ? "Ligado · " + r.cabo.ip : "Desconectado: confira o cabo na box e no roteador"));
      box.appendChild(cartao(r.internet.ok, "Internet", r.internet.ok ? "Funcionando" : "Sem internet: os fluxos não conseguem falar com a TFleet e o Supabase"));
      box.appendChild(cartao(r.tailscale.ok, "Tailscale (acesso de fora)",
        r.tailscale.ok ? "Ligado · " + r.tailscale.ip : "Desligado: de fora de casa você não entra aqui",
        r.tailscale.ok ? [] : [el("button", { classe: "btn mini primario", texto: "Ligar", onclick: ligarTailscale })]));
      box.appendChild(r.wifi.existe
        ? cartao(r.wifi.conectado ? true : null, "Wi-Fi (reserva)", r.wifi.conectado ? "Conectado em " + r.wifi.rede : r.wifi.ligado ? "Ligado, sem rede" : "Desligado", [
          el("button", { classe: "btn mini", texto: "Procurar redes", onclick: procurarWifi }),
          el("button", { classe: "btn mini", texto: r.wifi.ligado ? "Desligar" : "Ligar", onclick: function (ev) {
            rodarComBotao(ev.target, ["nmcli", "radio", "wifi", r.wifi.ligado ? "off" : "on"], "Wi-Fi").then(carregarRede);
          } })])
        : cartao(null, "Wi-Fi (reserva)", "Não disponível nesta box"));
      box.appendChild(r.bluetooth.existe
        ? cartao(r.bluetooth.ligado ? true : null, "Bluetooth", r.bluetooth.ligado ? "Ligado" : "Desligado", [
          el("button", { classe: "btn mini", texto: r.bluetooth.ligado ? "Desligar" : "Ligar", onclick: function (ev) {
            rodarComBotao(ev.target, ["bluetoothctl", "power", r.bluetooth.ligado ? "off" : "on"], "Bluetooth").then(carregarRede);
          } })])
        : cartao(null, "Bluetooth", "Não disponível nesta box"));
    }).catch(function () {
      limpar($("rede")).appendChild(el("p", { classe: "vazio", texto: "Não consegui verificar as conexões." }));
    });
  }
  function ligarTailscale(ev) {
    ev.target.disabled = true;
    saida("▶ Ligando o Tailscale...\n");
    rodar([SERVIDOR, "tailscale-ligar"], { silencioso: true }).then(function (out) {
      var link = (out.match(/https:\/\/login\.tailscale\.com\S+/) || [])[0];
      if (link) {
        saida("Abra este link, entre com a sua conta do Tailscale e clique em Connect:\n\n" + link + "\n", true);
        window.open(link, "_blank", "noopener");
      } else saida("Pronto. Clique em Verificar de novo.\n", true);
    }).catch(function (e) { saida("✖ " + (e.message || e) + "\n", true); })
      .then(function () { ev.target.disabled = false; setTimeout(carregarRede, 3000); });
  }
  function procurarWifi() {
    saida("▶ Procurando redes Wi-Fi...\n");
    rodar(["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "dev", "wifi", "list", "--rescan", "yes"], { silencioso: true }).then(function (out) {
      var redes = out.split("\n").filter(Boolean).map(function (l) { var p = l.split(/(?<!\\):/); return { uso: p[0], ssid: (p[1] || "").replace(/\\:/g, ":"), sinal: p[2], seg: p[3] }; })
        .filter(function (r) { return r.ssid; });
      if (!redes.length) { saida("Nenhuma rede encontrada.\n", true); return; }
      saida(redes.map(function (r, n) { return (n + 1) + ") " + r.ssid + "  sinal " + r.sinal + "%" + (r.uso === "*" ? "  (conectado)" : ""); }).join("\n") + "\n", true);
      var n = parseInt(prompt("Número da rede para conectar (ou Cancelar):"), 10);
      var r = redes[n - 1]; if (!r) return;
      var senha = r.seg ? prompt("Senha da rede " + r.ssid + ":") : "";
      if (senha === null) return;
      rodar(["nmcli", "dev", "wifi", "connect", r.ssid].concat(senha ? ["password", senha] : [])).then(carregarRede);
    }).catch(function (e) { saida("ERRO: " + (e.message || e), true); });
  }

  /* ---------- arquivos (tecnico) ---------- */
  function caminhoAtual() { return pastaAtual.caminho + (subpasta ? "/" + subpasta : ""); }
  function desenharAbas() {
    var box = limpar($("abas-pastas"));
    PASTAS.forEach(function (p) {
      box.appendChild(el("button", { classe: "aba" + (p === pastaAtual ? " ativa" : ""), texto: p.nome, onclick: function () {
        pastaAtual = p; subpasta = ""; desenharAbas(); carregarArquivos();
      } }));
    });
    $("dica-pasta").textContent = pastaAtual.dica;
    $("novo-arquivo").hidden = !pastaAtual.editavel;
  }
  function tamanho(b) { b = +b; return b > 1048576 ? (b / 1048576).toFixed(1) + " MB" : b > 1024 ? Math.round(b / 1024) + " KB" : b + " B"; }
  function carregarArquivos() {
    var dir = caminhoAtual();
    return rodar(["sh", "-c", 'mkdir -p "$1" && find "$1" -mindepth 1 -maxdepth 1 ! -name ".*" -printf "%y|%f|%s|%TY-%Tm-%Td %TH:%TM\\n"', "-", dir],
      { silencioso: true }).then(function (out) {
      var itens = out.split("\n").filter(Boolean).map(function (l) {
        var p = l.split("|"); return { tipo: p[0], nome: p[1], tam: p[2], data: p[3].slice(0, 16) };
      }).filter(function (i) { return !(pastaAtual.raiz && i.tipo === "d"); });
      itens.sort(function (a, b) { return (a.tipo === "d" ? 0 : 1) - (b.tipo === "d" ? 0 : 1) || a.nome.localeCompare(b.nome); });
      var box = limpar($("arquivos"));
      if (subpasta) {
        box.appendChild(el("div", { classe: "item" }, [el("button", { classe: "btn mini", texto: "← Voltar", onclick: function () {
          subpasta = subpasta.split("/").slice(0, -1).join("/"); carregarArquivos();
        } }), el("span", { classe: "info", texto: dir })]));
      }
      if (!itens.length) box.appendChild(el("p", { classe: "vazio", texto: "Pasta vazia." }));
      itens.forEach(function (i) {
        var caminho = dir + "/" + i.nome;
        var botoes = [];
        if (i.tipo === "d") {
          botoes.push(el("button", { classe: "btn mini", texto: "Abrir", onclick: function () { subpasta = (subpasta ? subpasta + "/" : "") + i.nome; carregarArquivos(); } }));
        } else {
          if (pastaAtual.editavel && /\.(js|json|txt|md|env|ya?ml|sh|sql|csv|html|css|py)$|^[^.]+$/i.test(i.nome))
            botoes.push(el("button", { classe: "btn mini", texto: "Abrir/editar", onclick: function () { abrirEditor(caminho); } }));
          botoes.push(el("button", { classe: "btn mini", texto: "Baixar", onclick: function () { baixar(caminho, i.nome); } }));
          if (pastaAtual.id !== "config")
            botoes.push(el("button", { classe: "btn mini perigo", texto: "Apagar", onclick: function () {
              if (confirm("Apagar " + i.nome + "? Não tem como desfazer.")) rodar(["rm", "-f", caminho]).then(carregarArquivos);
            } }));
        }
        box.appendChild(el("div", { classe: "item" }, [
          el("div", {}, [el("div", { classe: "nome", texto: (i.tipo === "d" ? "📁 " : "") + i.nome }),
            el("div", { classe: "info", texto: i.data + (i.tipo === "d" ? "" : " · " + tamanho(i.tam)) })]),
          el("div", { classe: "direita" }, botoes)
        ]));
      });
    }).catch(function () {
      limpar($("arquivos")).appendChild(el("p", { classe: "vazio", texto: "Sem acesso à pasta (ative o acesso administrativo)." }));
    });
  }
  function abrirEditor(caminho) {
    cockpit.file(caminho, { superuser: "require", max_read_size: 5 * 1024 * 1024 }).read().then(function (txt) {
      editando = caminho;
      $("editor-titulo").textContent = caminho;
      $("editor-texto").value = txt || "";
      $("editor-aviso").hidden = pastaAtual.id !== "config";
      $("editor-aviso").textContent = "Arquivo de configuração: confira antes de salvar e depois reinicie o programa.";
      $("editor").showModal();
    }).catch(function (e) { saida("ERRO ao abrir: " + (e.message || e)); });
  }
  function salvarEditor(ev) {
    ev.preventDefault();
    var txt = $("editor-texto").value;
    if (/\.json$/i.test(editando)) {
      try { JSON.parse(txt); } catch (e) { alert("O JSON tem erro e não foi salvo:\n" + e.message); return; }
    }
    cockpit.file(editando, { superuser: "require" }).replace(txt).then(function () {
      saida("✔ Salvo: " + editando); $("editor").close(); carregarArquivos();
    }).catch(function (e) { alert("Não salvou: " + (e.message || e)); });
  }
  function baixar(caminho, nome) {
    cockpit.file(caminho, { binary: true, superuser: "require", max_read_size: 512 * 1024 * 1024 }).read().then(function (dados) {
      var url = URL.createObjectURL(new Blob([dados]));
      var a = el("a", { href: url, download: nome }); document.body.appendChild(a); a.click(); a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 5000);
    }).catch(function (e) { saida("ERRO ao baixar: " + (e.message || e)); });
  }
  function novoArquivo() {
    var nome = prompt("Nome do arquivo (ex.: anotacoes.txt). Para criar uma pasta, termine com / (ex.: lotacao/)");
    if (!nome) return;
    nome = nome.replace(/[^\w.\-\/ ]+/g, "_").replace(/^\/+/, "");
    var alvo = caminhoAtual() + "/" + nome;
    if (/\/$/.test(nome)) { rodar(["mkdir", "-p", alvo]).then(carregarArquivos); return; }
    cockpit.file(alvo, { superuser: "require" }).replace("").then(function () { carregarArquivos(); abrirEditor(alvo); });
  }
  function enviarArquivos(arquivos) {
    Promise.all(Array.prototype.map.call(arquivos, function (a) {
      return a.arrayBuffer().then(function (buf) {
        return cockpit.file(caminhoAtual() + "/" + a.name.replace(/[^\w.\- ]+/g, "_"), { binary: true, superuser: "require" }).replace(new Uint8Array(buf));
      });
    })).then(function () { saida("✔ Enviado(s) para " + caminhoAtual()); carregarArquivos(); })
      .catch(function (e) { saida("ERRO ao enviar: " + (e.message || e)); });
  }

  /* ---------- terminal lateral (xterm.js + canal pty do Cockpit) ---------- */
  var term = null, canal = null, fit = null;
  function abrirTerminal() {
    if (!window.Terminal) { $("terminal").textContent = "Terminal indisponível (arquivos do xterm não carregaram)."; return; }
    if (canal) { try { canal.close(); } catch (e) { /* ja fechado */ } }
    if (!term) {
      term = new window.Terminal({ cursorBlink: true, fontSize: 13, scrollback: 3000,
        fontFamily: "ui-monospace, Menlo, Consolas, monospace", theme: { background: "#0f1419" } });
      fit = new window.FitAddon.FitAddon();
      term.loadAddon(fit);
      term.open($("terminal"));
      term.onData(function (d) { if (canal) canal.send(d); });
      new ResizeObserver(function () { ajustarTerminal(); }).observe($("terminal"));
    } else term.reset();
    canal = cockpit.channel({ payload: "stream", spawn: ["/bin/bash", "-l"], pty: true, directory: BASE,
      environ: ["TERM=xterm-256color", "LANG=C.UTF-8"] });
    canal.addEventListener("message", function (ev, dados) { term.write(dados); });
    canal.addEventListener("close", function (ev, opts) {
      term.write("\r\n\x1b[33m[terminal encerrado" + (opts && opts.problem ? ": " + opts.problem : "") + ". Clique em Reabrir.]\x1b[0m\r\n");
      canal = null;
    });
    ajustarTerminal();
  }
  function ajustarTerminal() {
    if (!term || !fit || !document.body.classList.contains("com-terminal")) return;
    try { fit.fit(); } catch (e) { return; }
    if (canal) canal.control({ window: { rows: term.rows, cols: term.cols } });
  }
  function digitarNoTerminal(cmd) {
    if (!document.body.classList.contains("com-terminal")) alternarTerminal();
    if (canal) { canal.send(cmd); term.focus(); }
  }
  function alternarTerminal() {
    var on = document.body.classList.toggle("com-terminal");
    $("alternar-terminal").textContent = on ? "Esconder terminal" : "Mostrar terminal";
    try { localStorage.setItem("central-terminal", on ? "1" : "0"); } catch (e) { /* sem storage */ }
    if (on && !canal) abrirTerminal();
    setTimeout(ajustarTerminal, 50);
  }

  /* ---------- ligacoes ---------- */
  function atualizarTudo() {
    return Promise.all([carregarStatus(), carregarFluxos(), carregarWhatsapp()]);
  }
  function iniciar() {
    $("abrir-n8n").href = linkN8n("/");
    $("abrir-evo").href = "http://" + host() + ":8080/manager";
    $("arquivo-fluxo").addEventListener("change", function (ev) { if (ev.target.files.length) importarFluxos(ev.target.files); ev.target.value = ""; });
    $("enviar-arquivo").addEventListener("change", function (ev) { if (ev.target.files.length) enviarArquivos(ev.target.files); ev.target.value = ""; });
    $("novo-arquivo").addEventListener("click", novoArquivo);
    $("editor-salvar").addEventListener("click", salvarEditor);
    $("cf-salvar").addEventListener("click", salvarConfigFluxo);
    $("limpar-saida").addEventListener("click", function () { saida(""); });
    $("verificar-rede").addEventListener("click", carregarRede);
    $("ver-logs").addEventListener("click", function () { rodar([SERVIDOR, "logs", $("log-servico").value, "120"]); });
    $("alternar-terminal").addEventListener("click", alternarTerminal);
    $("reabrir-terminal").addEventListener("click", abrirTerminal);
    $("atualizar-versoes").addEventListener("click", function (ev) {
      var n8n = prompt("Nova versão do n8n (a que eu te passar, ex.: 2.46.0). Deixe em branco para manter a atual:", "");
      if (n8n === null) return;
      var evo = prompt("Nova versão da Evolution (ex.: v2.3.8). Deixe em branco para manter a atual:", "");
      if (evo === null) return;
      if (!confirm("Atualizar agora? Faz backup antes e os fluxos param 1 a 3 minutos.")) return;
      var args = [SERVIDOR, "atualizar"];
      if (n8n.trim()) args.push("n8n=" + n8n.trim());
      if (evo.trim()) args.push("evolution=" + evo.trim());
      rodarComBotao(ev.target, args, "Atualizar n8n e Evolution");
    });
    $("reiniciar-box").addEventListener("click", function () {
      if (confirm("Reiniciar a TV Box? Tudo fica fora do ar por uns 2 minutos e volta sozinho.")) rodar(["systemctl", "reboot"]);
    });
    document.querySelectorAll("[data-cmd]").forEach(function (b) {
      b.addEventListener("click", function () {
        if (b.dataset.confirma && !confirm(b.dataset.confirma)) return;
        rodarComBotao(b, [SERVIDOR, b.dataset.cmd], b.textContent);
      });
    });
    document.querySelectorAll("[data-terminal]").forEach(function (b) {
      b.addEventListener("click", function () { digitarNoTerminal(b.dataset.terminal + "\r"); });
    });

    var terminalSalvo = null;
    try { terminalSalvo = localStorage.getItem("central-terminal"); } catch (e) { /* sem storage */ }
    if (terminalSalvo === "0") { document.body.classList.remove("com-terminal"); $("alternar-terminal").textContent = "Mostrar terminal"; }

    var perm = cockpit.permission({ admin: true });
    var aoMudar = function () {
      $("aviso-admin").hidden = perm.allowed !== false;
      if (perm.allowed) { atualizarTudo(); carregarRede(); carregarArquivos(); }
    };
    perm.addEventListener("changed", aoMudar);
    aoMudar();
    desenharAbas();
    if (document.body.classList.contains("com-terminal")) abrirTerminal();
    setInterval(function () { if (perm.allowed && !document.hidden) atualizarTudo(); }, 30000);
  }

  document.addEventListener("DOMContentLoaded", iniciar);
}());
