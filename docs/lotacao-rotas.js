// Monitor Frota — otimização de rotas (usado pelo lotacao.html; roda no navegador, sem nomes).
// Entradas: traçado real (rotas_tracado), pontos reais de embarque/desembarque (rota_pontos) e a
// ocupação por rota (lotacao_rotas). Saída: sugestões de 3 tipos:
//   SOBREPOSTA  trecho de rua com 2+ rotas do mesmo grupo pegando gente, onde uma a menos daria conta
//   LOTA_FIM    rota (IDA) que passa de "cap" no fim: quem pode pegar o fim, ou o começo dela
//   MOVER       pontos de uma rota cheia que ficam a até "raio" metros do caminho de outra com vaga
(function (root) {
  "use strict";
  const R = 6371000, rad = x => x * Math.PI / 180;
  const dist = (a, b) => 2 * R * Math.asin(Math.sqrt(Math.sin(rad(b[0] - a[0]) / 2) ** 2 + Math.cos(rad(a[0])) * Math.cos(rad(b[0])) * Math.sin(rad(b[1] - a[1]) / 2) ** 2));
  const norm = t => String(t || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toUpperCase()
    .replace(/\s*-\s*PASSAGEIRO\s*$/, "").replace(/\s+/g, " ").trim();
  const solta = t => norm(t).replace(/[^A-Z0-9]/g, "");
  const grupoDe = (linha, tipolinha) => {
    const n = norm(linha), t = String(tipolinha || "").toUpperCase();
    return /^CT\s*-?\s*\d/.test(n) ? "CT" : /(^|[^A-Z])ADM([^A-Z]|$)/.test(n) ? "ADM" : /TURNO/.test(n) ? "TURNO"
      : t.startsWith("ADM") ? "ADM" : t.startsWith("TURNO") ? "TURNO" : "OUTRO";
  };
  const turnoDe = t => (/TURNO\s*0?(\d+)/i.exec(t || "") || [])[1] || "";
  const CEL = 0.001;                                   // ~110 m: "mesma rua"
  const cel = (a, b) => Math.round(a / CEL) + ":" + Math.round(b / CEL);
  const BUSCA = 0.003;                                 // ~330 m: grade p/ achar rota perto de um ponto
  const bcel = (a, b) => Math.round(a / BUSCA) + ":" + Math.round(b / BUSCA);

  // pontos do traçado a cada ~"passo" metros, com a distância acumulada
  function densifica(pts, passo = 40) {
    const out = []; let acc = 0;
    for (let i = 0; i < pts.length; i++) {
      if (i) {
        const a = pts[i - 1], b = pts[i], d = dist(a, b), n = Math.min(Math.floor(d / passo), 2000);
        for (let k = 1; k <= n; k++) out.push({ p: [a[0] + (b[0] - a[0]) * k / (n + 1), a[1] + (b[1] - a[1]) * k / (n + 1)], s: acc + d * k / (n + 1) });
        acc += d;
      }
      out.push({ p: pts[i], s: acc });
    }
    return out;
  }

  function analisar(entrada) {
    const cap = entrada.cap || 40, lug = entrada.lug || 45, raio = entrada.raio || 300;
    // ---- traçados válidos (só a última coleta; rota que saiu do mapa some)
    let T = (entrada.tracado || []).filter(t => Array.isArray(t.pontos) && t.pontos.length > 1);
    const ult = Math.max(0, ...T.map(t => Date.parse(t.atualizado_em) || 0));
    if (ult) T = T.filter(t => (Date.parse(t.atualizado_em) || 0) > ult - 3 * 864e5);

    // ---- ocupação por linha + sentido (pior faixa de horário)
    const occ = {};
    for (const r of entrada.rotas || []) {
      const k = solta(r.linha) + "|" + r.tipo;
      const carga = Math.max(+r.media_viagem || 0, +r.media_7d || 0);
      const o = occ[k] || (occ[k] = { linha: r.linha, sentido: r.tipo, tipolinha: r.tipolinha, grupo: r.grupo || grupoDe(r.linha, r.tipolinha), carga: 0, onibus: 0, maximo: 0, status: [] });
      o.carga = Math.max(o.carga, carga); o.onibus = Math.max(o.onibus, +r.onibus_por_dia || 0); o.maximo = Math.max(o.maximo, +r.maximo || 0);
      o.status.push(r.status);
    }

    // ---- rotas = traçado + ocupação + pontos reais
    // mesmo nome + sentido + turno 2x no mapa (cadastro duplicado): fica o que tem mais paradas / traçado
    const melhor = {};
    for (const t of T) {
      const k = solta(t.linha) + "|" + t.sentido + "|" + turnoDe(t.tipolinha), o = melhor[k];
      const nota = x => (x.paradas || []).length * 1e4 + x.pontos.length;
      if (!o || nota(t) > nota(o)) melhor[k] = t;
    }
    T = Object.values(melhor);
    const rotas = [], porChave = {};
    for (const t of T) {
      const grupo = t.grupo || grupoDe(t.linha, t.tipolinha);
      const o = occ[solta(t.linha) + "|" + t.sentido];
      const id = t.codigo_linha + "|" + t.sentido;
      const d = densifica(t.pontos);
      const rt = { id, codigo: t.codigo_linha, linha: t.linha, sentido: t.sentido, tipolinha: t.tipolinha, grupo, turno: turnoDe(t.tipolinha),
        pontos: t.pontos, paradas: t.paradas || [], km: t.km, cadastrados: t.cadastrados, dens: d, occ: o || null,
        carga: o ? o.carga : null, vagas: o ? Math.floor(cap - o.carga) : null, vagas45: o ? Math.floor(lug - o.carga) : null, emb: [] };
      rotas.push(rt);
      (porChave[solta(t.linha) + "|" + t.sentido] = porChave[solta(t.linha) + "|" + t.sentido] || []).push(rt);
    }
    // a mesma linha pode ter 2 traçados (turno 01 e 02): fica com os dois, os pontos vão para o do turno certo
    for (const p of entrada.pontos || []) {
      const cands = porChave[solta(p.linha) + "|" + p.sentido]; if (!cands) continue;
      const tn = turnoDe(p.tipolinha);
      const rt = cands.find(c => tn && c.turno === tn) || cands[0];
      rt.emb.push({ lat: +p.lat, lon: +p.lon, dia: +p.por_dia || 0, depois: +p.depois_cap_dia || 0, hora: p.hora });
    }
    // grade de busca: rota -> pontos densificados por célula de ~330 m
    const grade = new Map();
    for (const rt of rotas) for (let i = 0; i < rt.dens.length; i += 2) {
      const q = rt.dens[i].p, k = bcel(q[0], q[1]);
      let m = grade.get(k); if (!m) grade.set(k, m = new Map());
      if (!m.has(rt.id)) m.set(rt.id, []);
      m.get(rt.id).push(q);
    }
    const porId = Object.fromEntries(rotas.map(r => [r.id, r]));
    // rotas que passam a até "raio" m de um ponto -> [{rt, d}]
    function perto(lat, lon, filtro) {
      const [a, b] = [Math.round(lat / BUSCA), Math.round(lon / BUSCA)], best = new Map();
      for (let i = -1; i <= 1; i++) for (let j = -1; j <= 1; j++) {
        const m = grade.get((a + i) + ":" + (b + j)); if (!m) continue;
        for (const [id, qs] of m) {
          if (filtro && !filtro(porId[id])) continue;
          for (const q of qs) { const d = dist([lat, lon], q); if (d <= raio && d < (best.get(id) ?? 1e9)) best.set(id, d); }
        }
      }
      return [...best].map(([id, d]) => ({ rt: porId[id], d: Math.round(d) })).sort((x, y) => x.d - y.d);
    }
    // posição ao longo da rota (metros) do ponto mais próximo do traçado
    function posicao(rt, lat, lon) {
      let bd = 1e9, bs = null;
      for (const q of rt.dens) { const d = Math.abs(q.p[0] - lat) + Math.abs(q.p[1] - lon); if (d < bd) { bd = d; bs = q; } }
      return bs && dist(bs.p, [lat, lon]) < 600 ? bs.s : null;
    }
    const paradaPerto = (rt, lat, lon) => {
      let b = null, bd = 1e9;
      for (const s of rt.paradas) { const d = dist([s.lat, s.lon], [lat, lon]); if (d < bd) { bd = d; b = s; } }
      return b && bd < 1500 ? b : null;
    };
    const mesmoGrupo = (a, b) => a.id !== b.id && a.sentido === b.sentido && a.grupo === b.grupo && a.grupo !== "OUTRO" &&
      (a.grupo !== "TURNO" || !a.turno || !b.turno || a.turno === b.turno);
    // zona de coleta: do 1o ao último ponto de embarque/parada (tira o trecho de estrada até a mina)
    for (const rt of rotas) {
      const ss = [...rt.emb.filter(e => e.dia >= 0.2), ...rt.paradas].map(e => posicao(rt, e.lat, e.lon)).filter(s => s != null);
      rt.zona = ss.length ? [Math.min(...ss) - 150, Math.max(...ss) + 150] : null;
      for (const e of rt.emb) e.s = posicao(rt, e.lat, e.lon);
    }

    const sug = [];
    const nomeV = rt => `${rt.linha}${rt.vagas != null ? ` (${rt.vagas > 0 ? rt.vagas + " vaga" + (rt.vagas > 1 ? "s" : "") + " até " + cap : "sem vaga até " + cap})` : " (sem viagens no período)"}`;

    // ---- 1) SOBREPOSTA: trechos de rua com várias rotas do mesmo grupo coletando
    const celRotas = new Map();
    for (const rt of rotas) {
      if (!rt.zona) continue;
      const vistos = new Set();
      for (const q of rt.dens) {
        if (q.s < rt.zona[0] || q.s > rt.zona[1]) continue;
        const k = rt.sentido + "|" + rt.grupo + (rt.grupo === "TURNO" ? rt.turno : "") + "|" + cel(q.p[0], q.p[1]);
        if (vistos.has(k)) continue; vistos.add(k);
        let s = celRotas.get(k); if (!s) celRotas.set(k, s = new Set()); s.add(rt.id);
      }
    }
    const trechos = new Map();   // conjunto de rotas -> {cels, m, centro}
    for (const rt of rotas) {
      if (!rt.zona) continue;
      let atual = null, ultS = null, ultCel = null;
      const fecha = () => { if (atual && atual.m >= 300) { const t = trechos.get(atual.key) || { key: atual.key, ids: atual.ids, m: 0, cels: new Set(), pts: [] }; t.m = Math.max(t.m, atual.m); atual.cels.forEach(c => t.cels.add(c)); t.pts.push(...atual.pts); trechos.set(atual.key, t); } atual = null; };
      for (const q of rt.dens) {
        if (q.s < rt.zona[0] || q.s > rt.zona[1]) continue;
        const ck = rt.sentido + "|" + rt.grupo + (rt.grupo === "TURNO" ? rt.turno : "") + "|" + cel(q.p[0], q.p[1]);
        if (ck === ultCel) { if (atual) { atual.m += q.s - ultS; ultS = q.s; } continue; }
        ultCel = ck;
        const ids = [...celRotas.get(ck)].sort();
        if (ids.length < 2) { fecha(); ultS = q.s; continue; }
        const key = ids.join(",");
        if (!atual || atual.key !== key) { fecha(); atual = { key, ids, m: 0, cels: new Set(), pts: [] }; }
        else atual.m += q.s - ultS;
        atual.cels.add(cel(q.p[0], q.p[1])); atual.pts.push(q.p); ultS = q.s;
      }
      fecha();
    }
    for (const t of trechos.values()) {
      if (t.m < 600) continue;
      const rs = t.ids.map(id => porId[id]);
      const vizinho = (la, lo) => { const a = Math.round(la / CEL), b = Math.round(lo / CEL); for (let i = -1; i <= 1; i++) for (let j = -1; j <= 1; j++) if (t.cels.has((a + i) + ":" + (b + j))) return true; return false; };
      const dem = rs.map(r => Math.round(r.emb.filter(e => vizinho(e.lat, e.lon)).reduce((s, e) => s + e.dia, 0) * 10) / 10);
      const meio = t.pts[Math.floor(t.pts.length / 2)];
      const par = paradaPerto(rs[0], meio[0], meio[1]) || rs.map(r => paradaPerto(r, meio[0], meio[1])).find(Boolean);
      // qual rota pode sair do trecho: a com menos gente ali, se as outras têm vaga p/ ela
      let saida = null;
      rs.forEach((r, i) => {
        if (dem[i] < 1) return;
        const outrasVagas = rs.reduce((s, o, j) => s + (j !== i && o.vagas > 0 ? o.vagas : 0), 0);
        if (dem[i] <= outrasVagas && (!saida || dem[i] < saida.d)) saida = { r, i, d: dem[i], outrasVagas };
      });
      const total = dem.reduce((a, b) => a + b, 0);
      const coletam = dem.filter(x => x >= 1).length;
      if (coletam < 2) continue;              // só uma rota pega gente ali: o resto está só de passagem
      const passagem = rs.filter((r, i) => dem[i] < 1);
      const tn = rs[0].turno ? ", turno " + rs[0].turno : "";
      sug.push({ tipo: "SOBREPOSTA", peso: coletam * 10 + t.m / 1000 + (saida ? 5 : 0), sentido: rs[0].sentido, grupo: rs[0].grupo,
        rotas: rs.map(r => r.id), km: Math.round(t.m / 100) / 10, centro: meio, trecho: t.pts, demanda: dem, saida: saida && saida.r.id,
        titulo: `${coletam} rotas pegando gente no mesmo trecho${par && par.endereco ? " · " + par.endereco.split(",").slice(0, 2).join(",") : ""}`,
        texto: `${String(Math.round(t.m / 100) / 10).replace(".", ",")} km de rua (${rs[0].sentido}${tn}) onde ${rs.filter((r, i) => dem[i] >= 1).map(r => `<b>${esc(r.linha)}</b> ~${fmt(dem[rs.indexOf(r)])}/dia`).join(", ")} pegam gente: ~${fmt(total)} pessoas/dia no total.` +
          (passagem.length ? ` <span class="muted">Só de passagem: ${passagem.map(r => esc(r.linha)).join(", ")}.</span>` : "") +
          (saida ? ` <b>${coletam - 1} rota${coletam - 1 > 1 ? "s" : ""} bastaria${coletam - 1 > 1 ? "m" : ""}:</b> ${esc(saida.r.linha)} pega só ~${fmt(saida.d)}/dia aqui e as outras têm ${saida.outrasVagas} vagas até ${cap}; ela pode deixar de passar nesse trecho e essas pessoas embarcam nas outras.`
                 : ` Sem vaga sobrando nas outras para tirar uma rota daqui.`) });
    }

    // ---- 2) LOTA_FIM e 3) MOVER (rota cheia)
    for (const rt of rotas) {
      if (!rt.occ) continue;
      const cheia = rt.carga > cap || rt.emb.some(e => e.depois > 0);
      if (!cheia) continue;
      const alvo = o => mesmoGrupo(rt, o) && o.vagas > 0;
      const excesso = Math.round(rt.emb.reduce((s, e) => s + e.depois, 0) * 10) / 10;
      if (rt.sentido === "IDA" && excesso >= 1) {
        const fim = rt.emb.filter(e => e.depois > 0 && e.s != null).sort((a, b) => a.s - b.s);
        const ini = rt.emb.filter(e => e.depois === 0 && e.s != null && e.dia > 0).sort((a, b) => a.s - b.s);
        if (fim.length) {
          const par = paradaPerto(rt, fim[0].lat, fim[0].lon);
          // quem passa perto do fim
          const cobreFim = {};
          for (const e of fim) for (const { rt: o, d } of perto(e.lat, e.lon, alvo)) {
            const c = cobreFim[o.id] || (cobreFim[o.id] = { o, n: 0, d: 1e9 }); c.n += e.depois; c.d = Math.min(c.d, d);
          }
          const fimOp = Object.values(cobreFim).sort((a, b) => Math.min(b.n, b.o.vagas) - Math.min(a.n, a.o.vagas));
          // quem passa perto do começo (para esta rota começar mais à frente)
          let acc = 0; const comeco = [];
          for (const e of ini) { if (acc >= excesso) break; comeco.push(e); acc += e.dia; }
          const cobreIni = {};
          for (const e of comeco) for (const { rt: o, d } of perto(e.lat, e.lon, alvo)) {
            const c = cobreIni[o.id] || (cobreIni[o.id] = { o, n: 0, d: 1e9 }); c.n += e.dia; c.d = Math.min(c.d, d);
          }
          const iniOp = Object.values(cobreIni).sort((a, b) => Math.min(b.n, b.o.vagas) - Math.min(a.n, a.o.vagas));
          const parIni = comeco.length ? paradaPerto(rt, comeco[0].lat, comeco[0].lon) : null;
          let txt = `Passa de ${cap} no fim do caminho: ~<b>${fmt(excesso)} pessoa(s)/dia</b> entram depois do ${cap}º${par && par.endereco ? `, a partir de <b>${esc(par.endereco.split(",").slice(0, 2).join(","))}</b>${par.horario ? " (" + par.horario + ")" : ""}` : ""}.`;
          if (fimOp.length) txt += `<br>➜ <b>Pegar o fim com outra rota:</b> ${fimOp.slice(0, 3).map(c => `${esc(nomeV(c.o))} passa a ${c.d} m`).join("; ")}.`;
          if (iniOp.length) txt += `<br>➜ <b>Ou começar mais à frente:</b> o começo${parIni && parIni.endereco ? ` (${esc(parIni.endereco.split(",").slice(0, 2).join(","))})` : ""}, ~${fmt(acc)}/dia, fica perto de ${iniOp.slice(0, 3).map(c => `${esc(nomeV(c.o))} a ${c.d} m`).join("; ")}; ela pega o começo e esta rota ganha espaço para o fim.`;
          if (!fimOp.length && !iniOp.length) txt += `<br>Nenhuma rota do mesmo grupo com vaga passa a até ${raio} m do fim nem do começo: ônibus extra ou dividir a rota.`;
          sug.push({ tipo: "LOTA_FIM", peso: 50 + excesso, sentido: rt.sentido, grupo: rt.grupo, rotas: [rt.id, ...fimOp.slice(0, 3).map(c => c.o.id), ...iniOp.slice(0, 3).map(c => c.o.id)],
            centro: [fim[0].lat, fim[0].lon], pontosFim: fim.map(e => [e.lat, e.lon]), pontosIni: comeco.map(e => [e.lat, e.lon]),
            titulo: `${rt.linha} lota no fim`, texto: txt, principal: rt.id });
        }
      }
      // mover: pontos da rota cheia perto do caminho de outra com vaga
      const sobra = Math.max(Math.ceil(rt.carga - cap), Math.ceil(excesso));
      if (sobra <= 0) continue;
      const mov = {};
      for (const e of rt.emb) {
        if (e.dia < 0.3) continue;
        for (const { rt: o, d } of perto(e.lat, e.lon, alvo)) {
          const m = mov[o.id] || (mov[o.id] = { o, n: 0, pts: [], d: 1e9 }); m.n += e.dia; m.pts.push([e.lat, e.lon, e.dia, d]); m.d = Math.min(m.d, d);
        }
      }
      const ops = Object.values(mov).filter(m => m.n >= 0.5).sort((a, b) => Math.min(b.n, b.o.vagas) - Math.min(a.n, a.o.vagas)).slice(0, 4);
      if (ops.length) sug.push({ tipo: "MOVER", peso: 30 + sobra, sentido: rt.sentido, grupo: rt.grupo, rotas: [rt.id, ...ops.map(m => m.o.id)], principal: rt.id,
        centro: ops[0].pts[0], pontos: ops.flatMap(m => m.pts.map(p => [p[0], p[1]])),
        titulo: `${rt.linha}: remanejar ~${sobra} pessoa(s)`,
        texto: `Média de ${fmt(rt.carga)} por viagem (ideal ${cap}, ${lug} lugares). Pessoas que embarcam a até ${raio} m do caminho de outra rota do mesmo grupo com vaga:` +
          `<ul>${ops.map(m => `<li><b>${esc(m.o.linha)}</b>: ~${fmt(m.n)}/dia embarcam a até ${Math.max(...m.pts.map(p => p[3]))} m do caminho dela · ${m.o.vagas} vaga(s) até ${cap} (${m.o.vagas45} até ${lug})${m.n > m.o.vagas ? ` · cabem ~${m.o.vagas}` : ""}</li>`).join("")}</ul>` });
    }
    sug.sort((a, b) => b.peso - a.peso);
    return { rotas, porId, sug, ultimaColeta: ult ? new Date(ult) : null };
  }
  const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const fmt = n => (+n).toLocaleString("pt-BR", { maximumFractionDigits: 1 });
  const api = { analisar, norm, solta, densifica, dist };
  if (typeof module !== "undefined") module.exports = api; else root.Otim = api;
})(typeof window !== "undefined" ? window : globalThis);
