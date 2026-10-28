/* Central da Frota: pagina do Cockpit que reune fluxos do n8n, WhatsApp, arquivos, rede e manutencao.
   Tudo roda pelo comando /usr/local/bin/servidor (com acesso administrativo do Cockpit). */
(function () {
  "use strict";

  var BASE = "/opt/servidor";
  var SERVIDOR = "/usr/local/bin/servidor";
  var PASTAS = [
    { id: "codigos", nome: "Códigos", caminho: BASE + "/codigos", editavel: true,
      dica: "Seus códigos e anotações do servidor, organizados em pastas (ex.: códigos dos nós Code de cada fluxo). Clique para abrir e editar." },
    { id: "importar", nome: "Fluxos para importar", caminho: BASE + "/importar", editavel: true,
      dica: "Arquivos .json que o botão Importar coloca aqui. Os já importados ganham o final .importado." },
    { id: "backups", nome: "Backups", caminho: BASE + "/backups", editavel: false,
      dica: "Cópias diárias dos fluxos e credenciais (criptografadas). Clique em Baixar para guardar uma cópia no seu PC: se o cartão SD estragar, é ela que salva." },
    { id: "config", nome: "Configuração", caminho: BASE, editavel: true, raiz: true,
      dica: "Arquivos de configuração do servidor. Só mexa se eu pedir: um erro aqui pode parar tudo. Depois de salvar, reinicie o programa." }
  ];
  var pastaAtual = PASTAS[0];
  var subpasta = "";
  var editando = null;

  var $ = function (id) { return document.getElementById(id); };
  function el(tag, attrs, filhos) {
    var e = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (k) {
      if (k === "texto") e.textContent = attrs[k];
      else if (k === "classe") e.className = attrs[k];
      else if (k.indexOf("on") === 0) e.addEventListener(k.slice(2), attrs[k]);
      else e.setAttribute(k, attrs[k]);
    });
    (filhos || []).forEach(function (f) { if (f) e.appendChild(typeof f === "string" ? document.createTextNode(f) : f); });
    return e;
  }
  function host() {
    try { return window.top.location.hostname; } catch (e) { return window.location.hostname; }
  }
  function linkN8n(caminho) { return "http://" + host() + ":5678" + (caminho || ""); }

  /* ---------- execucao de comandos ---------- */
  function saida(txt, anexar) {
    var s = $("saida");
    s.textContent = anexar ? s.textContent + txt : txt;
    s.scrollTop = s.scrollHeight;
  }
  function rodar(args, opts) {
    opts = opts || {};
    return cockpit.spawn(args, { superuser: "require", err: "out" }).then(function (out) {
      if (!opts.silencioso) saida(out || "(concluído sem mensagens)");
      return out;
    }, function (ex) {
      if (!opts.silencioso) saida("ERRO: " + (ex.message || ex) + "\n" + (ex.problem === "access-denied"
        ? "Ative o acesso administrativo (botão 'Acesso limitado' no topo)." : ""));
      throw ex;
    });
  }
  function rodarComBotao(botao, args, titulo) {
    botao.disabled = true;
    saida("▶ " + titulo + "...\n");
    var proc = cockpit.spawn(args, { superuser: "require", err: "out" });
    proc.stream(function (d) { saida(d, true); });
    return proc.then(function () { saida("\n✔ " + titulo + ": concluído.\n", true); },
      function (ex) { saida("\n✖ " + titulo + ": " + (ex.message || ex) + "\n", true); })
      .then(function () { botao.disabled = false; atualizarTudo(); });
  }
  function json(args) { return rodar(args, { silencioso: true }).then(function (t) { return JSON.parse(t); }); }

  /* ---------- resumo do topo e servicos ---------- */
  function carregarStatus() {
    return json([SERVIDOR, "status-json"]).then(function (s) {
      var livrePct = Math.round(100 * s.ram_livre_mb / s.ram_total_mb);
      var discoPct = Math.round(100 * s.disco_usado_gb / s.disco_total_gb);
      var chips = [
        ["RAM livre " + s.ram_livre_mb + " de " + s.ram_total_mb + " MB", livrePct < 15 ? "erro" : livrePct < 30 ? "atencao" : "ok"],
        ["Cartão " + s.disco_usado_gb + " de " + s.disco_total_gb + " GB", discoPct > 90 ? "erro" : discoPct > 75 ? "atencao" : "ok"],
        ["Temperatura " + s.temp_c + " °C", s.temp_c > 80 ? "erro" : s.temp_c > 70 ? "atencao" : "ok"],
        ["Casa: " + (s.ip_casa || "?"), ""],
        [s.ip_tailscale ? "Tailscale: " + s.ip_tailscale : "Tailscale desligado", s.ip_tailscale ? "" : "atencao"],
        [s.ultimo_backup ? "Último backup: " + s.ultimo_backup.replace("backup-", "").replace(".tar.gz", "") : "Sem backup ainda", s.ultimo_backup ? "" : "atencao"]
      ];
      var r = $("resumo"); r.textContent = "";
      chips.forEach(function (c) { r.appendChild(el("span", { classe: "chip " + c[1], texto: c[0] })); });

      var nomes = { n8n: "n8n (fluxos)", evolution: "Evolution (WhatsApp)", postgres: "Banco da Evolution", redis: "Cache da Evolution" };
      var box = $("servicos"); box.textContent = "";
      if (!s.servicos.length) box.appendChild(el("p", { classe: "vazio", texto: "Nenhum programa encontrado. O instalador rodou até o fim?" }));
      s.servicos.forEach(function (sv) {
        var rodando = sv.estado === "running";
        box.appendChild(el("div", { classe: "item" }, [
          el("div", {}, [el("div", { classe: "nome" }, [el("span", { classe: "ponto " + (rodando ? "ok" : "erro") }), nomes[sv.nome] || sv.nome]),
            el("div", { classe: "info", texto: sv.detalhe })]),
          el("div", { classe: "direita" }, [
            el("button", { classe: "btn mini", texto: "Logs", onclick: function () { rodar([SERVIDOR, "logs", sv.nome, "80"]); } }),
            el("button", { classe: "btn mini", texto: "Reiniciar", onclick: function (ev) { rodarComBotao(ev.target, [SERVIDOR, "reiniciar", sv.nome], "Reiniciar " + sv.nome); } })
          ])
        ]));
      });
    }).catch(function () {
      $("resumo").textContent = "";
      $("resumo").appendChild(el("span", { classe: "chip erro", texto: "Sem acesso ao status" }));
    });
  }

  /* ---------- fluxos ---------- */
  function carregarFluxos() {
    return json([SERVIDOR, "fluxos-json"]).then(function (lista) {
      var box = $("fluxos"); box.textContent = "";
      if (!lista.length) {
        box.appendChild(el("p", { classe: "vazio", texto: "Nenhum fluxo ainda. Abra o n8n uma vez (para criar o usuário dono) e use Importar fluxo." }));
        return;
      }
      lista.forEach(function (f) {
        box.appendChild(el("div", { classe: "item" }, [
          el("div", {}, [el("div", { classe: "nome" }, [el("span", { classe: "ponto " + (f.ativo ? "ok" : "") }), f.nome]),
            el("div", { classe: "info", texto: (f.ativo ? "Ligado, roda sozinho" : "Desligado") + " · id " + f.id })]),
          el("div", { classe: "direita" }, [
            el("a", { classe: "btn mini", texto: "Editar", href: linkN8n("/workflow/" + f.id), target: "_blank", rel: "noopener" }),
            el("button", { classe: "btn mini", texto: f.ativo ? "Desligar" : "Ligar", onclick: function (ev) {
              rodarComBotao(ev.target, [SERVIDOR, f.ativo ? "fluxo-desligar" : "fluxo-ligar", f.id], (f.ativo ? "Desligar " : "Ligar ") + f.nome);
            } })
          ])
        ]));
      });
    }).catch(function () {
      $("fluxos").textContent = "";
      $("fluxos").appendChild(el("p", { classe: "vazio", texto: "Não consegui ler os fluxos (o n8n está ligado?)." }));
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
      return rodarComBotao($("arquivo-fluxo").parentNode, [SERVIDOR, "importar"], "Importar no n8n");
    }).catch(function (e) { saida("✖ " + (e.message || e) + "\n", true); });
  }

  /* ---------- whatsapp ---------- */
  function carregarWhatsapp() {
    return json([SERVIDOR, "whatsapp-json"]).then(function (w) {
      var box = $("whatsapp"); box.textContent = "";
      if (!w.ok) { box.appendChild(el("p", { classe: "vazio", texto: "A Evolution não respondeu." })); return; }
      if (!w.instancias.length) {
        box.appendChild(el("p", { classe: "vazio", texto: "Nenhum número cadastrado ainda. Abra a tela do QR e crie a instância." }));
        return;
      }
      w.instancias.forEach(function (i) {
        var on = i.estado === "open";
        box.appendChild(el("div", { classe: "item" }, [
          el("div", { classe: "nome" }, [el("span", { classe: "ponto " + (on ? "ok" : "erro") }), i.nome + (i.numero ? " · " + i.numero : "")]),
          el("span", { classe: "chip " + (on ? "ok" : "erro"), texto: on ? "conectado" : "desconectado" })
        ]));
      });
    }).catch(function () {});
  }

  /* ---------- arquivos ---------- */
  function caminhoAtual() { return pastaAtual.caminho + (subpasta ? "/" + subpasta : ""); }
  function desenharAbas() {
    var box = $("abas-pastas"); box.textContent = "";
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
    return rodar(["sh", "-c", 'mkdir -p "$1" && find "$1" -mindepth 1 -maxdepth 1 -printf "%y|%f|%s|%TY-%Tm-%Td %TH:%TM\\n"', "-", dir],
      { silencioso: true }).then(function (out) {
      var itens = out.split("\n").filter(Boolean).map(function (l) {
        var p = l.split("|"); return { tipo: p[0], nome: p[1], tam: p[2], data: p[3].slice(0, 16) };
      }).filter(function (i) { return !(pastaAtual.raiz && i.tipo === "d"); });
      itens.sort(function (a, b) { return (a.tipo === "d" ? 0 : 1) - (b.tipo === "d" ? 0 : 1) || a.nome.localeCompare(b.nome); });
      var box = $("arquivos"); box.textContent = "";
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
          if (pastaAtual.editavel && /\.(js|json|txt|md|env|ya?ml|sh|sql|csv|html|css|py)$|^\.env$|^[^.]+$/i.test(i.nome))
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
      $("arquivos").textContent = "";
      $("arquivos").appendChild(el("p", { classe: "vazio", texto: "Sem acesso à pasta (ative o acesso administrativo)." }));
    });
  }
  function abrirEditor(caminho) {
    cockpit.file(caminho, { superuser: "require", max_read_size: 5 * 1024 * 1024 }).read().then(function (txt) {
      editando = caminho;
      $("editor-titulo").textContent = caminho;
      $("editor-texto").value = txt || "";
      var aviso = $("editor-aviso");
      aviso.hidden = pastaAtual.id !== "config";
      aviso.textContent = "Arquivo de configuração: confira antes de salvar e depois reinicie o programa no bloco 'Programas do servidor'.";
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
    var nome = prompt("Nome do arquivo (ex.: alerta-roteador.js). Para criar uma pasta, termine com / (ex.: lotacao/)");
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

  /* ---------- rede ---------- */
  function carregarRede() {
    var box = $("rede"); box.textContent = "";
    var cabo = rodar(["sh", "-c", "ip -br -4 addr show | grep -E '^(e|end)' || true"], { silencioso: true }).then(function (out) {
      var l = out.trim().split("\n").filter(Boolean)[0];
      var p = l ? l.split(/\s+/) : [];
      var on = p[1] === "UP";
      box.appendChild(el("div", { classe: "item" }, [
        el("div", { classe: "nome" }, [el("span", { classe: "ponto " + (on ? "ok" : "erro") }), "Cabo (" + (p[0] || "?") + ")"]),
        el("span", { classe: "info", texto: on ? (p[2] || "") : "desconectado" })
      ]));
    });
    var wifi = rodar(["sh", "-c", "command -v nmcli >/dev/null && nmcli -t -f TYPE,STATE,CONNECTION dev | grep '^wifi' || echo SEM"], { silencioso: true }).then(function (out) {
      var linha = out.trim().split("\n")[0];
      var item = el("div", { classe: "item" });
      if (linha === "SEM" || !linha) {
        item.appendChild(el("div", { classe: "nome" }, [el("span", { classe: "ponto" }), "Wi-Fi"]));
        item.appendChild(el("span", { classe: "info", texto: "não disponível nesta box" }));
      } else {
        var p = linha.split(/(?<!\\):/);
        item.appendChild(el("div", { classe: "nome" }, [el("span", { classe: "ponto " + (p[1] === "connected" ? "ok" : "") }),
          "Wi-Fi" + (p[1] === "connected" ? " · " + p[2].replace(/\\:/g, ":") : "")]));
        item.appendChild(el("div", { classe: "direita" }, [
          el("button", { classe: "btn mini", texto: "Procurar redes", onclick: procurarWifi }),
          el("button", { classe: "btn mini", texto: p[1] === "unavailable" ? "Ligar" : "Desligar", onclick: function (ev) {
            rodarComBotao(ev.target, ["nmcli", "radio", "wifi", p[1] === "unavailable" ? "on" : "off"], "Wi-Fi");
          } })
        ]));
      }
      box.appendChild(item);
    });
    var bt = rodar(["sh", "-c", "command -v bluetoothctl >/dev/null && timeout 5 bluetoothctl show 2>&1 || echo SEM"], { silencioso: true }).then(function (out) {
      var item = el("div", { classe: "item" });
      if (/SEM|No default controller|not available/i.test(out) || !/Controller/.test(out)) {
        item.appendChild(el("div", { classe: "nome" }, [el("span", { classe: "ponto" }), "Bluetooth"]));
        item.appendChild(el("span", { classe: "info", texto: "não disponível nesta box" }));
      } else {
        var ligado = /Powered: yes/.test(out);
        item.appendChild(el("div", { classe: "nome" }, [el("span", { classe: "ponto " + (ligado ? "ok" : "") }), "Bluetooth " + (ligado ? "ligado" : "desligado")]));
        item.appendChild(el("button", { classe: "btn mini", texto: ligado ? "Desligar" : "Ligar", onclick: function (ev) {
          rodarComBotao(ev.target, ["bluetoothctl", "power", ligado ? "off" : "on"], "Bluetooth");
        } }));
      }
      box.appendChild(item);
    });
    return Promise.all([cabo, wifi, bt]).catch(function () {});
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
      var args = ["nmcli", "dev", "wifi", "connect", r.ssid].concat(senha ? ["password", senha] : []);
      rodar(args).then(carregarRede);
    }).catch(function (e) { saida("ERRO: " + (e.message || e), true); });
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
    $("limpar-saida").addEventListener("click", function () { saida(""); });
    $("ver-logs").addEventListener("click", function () { rodar([SERVIDOR, "logs", $("log-servico").value, "120"]); });
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
      b.addEventListener("click", function () {
        if (b.dataset.terminal) saida("No terminal que vai abrir, digite:\n\n    " + b.dataset.terminal + "\n\ne siga as perguntas.");
        cockpit.jump("/system/terminal");
      });
    });

    var perm = cockpit.permission({ admin: true });
    var aoMudar = function () {
      $("aviso-admin").hidden = perm.allowed !== false;
      if (perm.allowed) { atualizarTudo(); carregarArquivos(); carregarRede(); }
    };
    perm.addEventListener("changed", aoMudar);
    aoMudar();
    desenharAbas();
    setInterval(function () { if (perm.allowed && !document.hidden) atualizarTudo(); }, 30000);
  }

  document.addEventListener("DOMContentLoaded", iniciar);
}());
