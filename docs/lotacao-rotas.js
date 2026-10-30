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

  // dentro da área da garagem (polígono [[lat,lon],...]) ou, sem área, no raio
  function naGaragem(g, lat, lon) {
    const P = Array.isArray(g.poligono) ? g.poligono : null;
    if (!P || P.length < 3) return dist([g.lat, g.lon], [lat, lon]) <= (g.raio_m || 300);
    let dentro = false;
    for (let i = 0, j = P.length - 1; i < P.length; j = i++) {
      const [yi, xi] = P[i], [yj, xj] = P[j];
      if ((yi > lat) !== (yj > lat) && lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) dentro = !dentro;
    }
    return dentro;
  }
  function analisar(entrada) {
    const cap = entrada.cap || 40, lug = entrada.lug || 45, raio = entrada.raio || 300;
    const garagens = (entrada.garagens || []).filter(g => g.lat != null && g.lon != null);
    // ---- traçados válidos (só a última coleta; rota que saiu do mapa some)
    let T = (entrada.tracado || []).filter(t => Array.isArray(t.pontos) && t.pontos.length > 1);
    const ult = Math.max(0, ...T.map(t => Date.parse(t.atualizado_em) || 0));
    if (ult) T = T.filter(t => (Date.parse(t.atualizado_em) || 0) > ult - 3 * 864e5);

    // ---- ocupação por linha + sentido (pior faixa de horário)
    const occ = {};
    for (const r of entrada.rotas || []) {
      const k = solta(r.linha) + "|" + r.tipo + "|" + turnoDe(r.tipolinha);
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
      const o = occ[solta(t.linha) + "|" + t.sentido + "|" + turnoDe(t.tipolinha)] || occ[solta(t.linha) + "|" + t.sentido + "|"];
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
      if (garagens.some(g => naGaragem(g, +p.lat, +p.lon))) continue;   // embarque "na garagem" = erro de GPS
      rt.linhaBdv = p.linha;
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
    function proj(rt, lat, lon) {
      let bd = 1e9, bs = null;
      for (const q of rt.dens) { const d = Math.abs(q.p[0] - lat) + Math.abs(q.p[1] - lon); if (d < bd) { bd = d; bs = q; } }
      return bs ? { s: bs.s, p: bs.p, d: dist(bs.p, [lat, lon]) } : null;
    }
    function posicao(rt, lat, lon) { const q = proj(rt, lat, lon); return q && q.d < 600 ? q.s : null; }
    // trechos do traçado de "rt" a até "r" metros de algum dos pontos -> lista de polilinhas
    function segPerto(rt, pts, r = 200) {
      const out = []; let cur = null;
      for (const q of rt.dens) {
        const ok = pts.some(x => Math.abs(x[0] - q.p[0]) < 0.004 && Math.abs(x[1] - q.p[1]) < 0.004 && dist(x, q.p) <= r);
        if (ok) { (cur || (cur = [])).push(q.p); } else if (cur) { if (cur.length > 1) out.push(cur); cur = null; }
      }
      if (cur && cur.length > 1) out.push(cur);
      return out;
    }
    // seta: do ponto onde a pessoa embarca até o ponto mais perto da rota que recebe
    const seta = (x, o) => { const q = proj(o, x[0], x[1]); return q ? { de: [x[0], x[1]], para: q.p } : null; };
    const paradaPerto = (rt, lat, lon) => {
      let b = null, bd = 1e9;
      for (const s of rt.paradas) { const d = dist([s.lat, s.lon], [lat, lon]); if (d < bd) { bd = d; b = s; } }
      return b && bd < 1500 ? b : null;
    };
    const mesmoGrupo = (a, b) => a.id !== b.id && a.sentido === b.sentido && a.grupo === b.grupo && a.grupo !== "OUTRO" &&
      (a.grupo !== "TURNO" || !a.turno || !b.turno || a.turno === b.turno);
    // zona de coleta: do 1o ao último ponto de embarque/parada (tira o trecho de estrada até a mina)
    for (const rt of rotas) {
      // embarque longe do bairro da rota (ex.: na entrada da mina) não é coleta: fica fora
      if (rt.emb.length > 2) {
        const md = k => rt.emb.map(e => e[k]).sort((x, y) => x - y)[Math.floor(rt.emb.length / 2)], c = [md("lat"), md("lon")];
        rt.emb = rt.emb.filter(e => dist([e.lat, e.lon], c) < 8000);
      }
      const base = rt.emb.filter(e => e.dia >= 0.2);
      const ss = (base.length ? base : rt.paradas).map(e => posicao(rt, e.lat, e.lon)).filter(s => s != null);
      rt.zona = ss.length ? [Math.min(...ss) - 150, Math.max(...ss) + 150] : null;
      // embarque a mais de 300 m do traçado da própria rota = GPS do celular fora do lugar: sai da análise
      rt.foraGps = 0;
      rt.emb = rt.emb.filter(e => {
        const q = proj(rt, e.lat, e.lon);
        if (!q || q.d > 300) { rt.foraGps += e.dia; return false; }
        e.s = q.s; e.snap = q.p; return true;
      });
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
    const rua = par => par && par.endereco ? par.endereco.split(",").slice(0, 2).join(",").trim() : null;
    const nPes = n => { const k = Math.max(1, Math.round(n)); return k + (k > 1 ? " pessoas" : " pessoa"); };
    const lista = xs => xs.length > 1 ? xs.slice(0, -1).join(", ") + " e " + xs[xs.length - 1] : xs.join("");
    const vagasTxt = o => `${o.vagas} vaga${o.vagas > 1 ? "s" : ""} até ${cap}`;
    for (const t of trechos.values()) {
      if (t.m < 600) continue;
      const rs = t.ids.map(id => porId[id]);
      const vizinho = (la, lo) => { const a = Math.round(la / CEL), b = Math.round(lo / CEL); for (let i = -1; i <= 1; i++) for (let j = -1; j <= 1; j++) if (t.cels.has((a + i) + ":" + (b + j))) return true; return false; };
      const noTrecho = rs.map(r => r.emb.filter(e => vizinho(e.lat, e.lon)));
      const dem = noTrecho.map(l => Math.round(l.reduce((s, e) => s + e.dia, 0) * 10) / 10);
      const meio = t.pts[Math.floor(t.pts.length / 2)];
      const par = paradaPerto(rs[0], meio[0], meio[1]) || rs.map(r => paradaPerto(r, meio[0], meio[1])).find(Boolean);
      const coletam = dem.filter(x => x >= 1).length;
      if (coletam < 2) continue;              // só uma rota pega gente ali: o resto está só de passagem
      // qual rota pode sair do trecho: a com menos gente ali, se as outras têm vaga p/ ela
      let saida = null;
      rs.forEach((r, i) => {
        if (dem[i] < 1) return;
        const outrasVagas = rs.reduce((s, o, j) => s + (j !== i && dem[j] >= 1 && o.vagas > 0 ? o.vagas : 0), 0);
        if (dem[i] <= outrasVagas && (!saida || dem[i] < saida.d)) saida = { r, i, d: dem[i], outrasVagas };
      });
      if (!saida) continue;                   // ninguém tem vaga p/ absorver: não é sugestão
      const ficam = rs.filter((r, i) => dem[i] >= 1 && r !== saida.r);
      const km = String(Math.round(t.m / 100) / 10).replace(".", ",");
      const onde = rua(par);
      const papel = { [saida.r.id]: "sai" }; ficam.forEach(r => papel[r.id] = "recebe");
      sug.push({ tipo: "SOBREPOSTA", peso: coletam * 10 + t.m / 1000 + 5, sentido: rs[0].sentido, grupo: rs[0].grupo, turno: rs[0].turno,
        rotas: rs.filter((r, i) => dem[i] >= 1).map(r => r.id), papel, centro: meio, trecho: t.pts, principal: saida.r.id,
        pontos: noTrecho[saida.i].map(e => [e.lat, e.lon]),
        titulo: `${coletam} rotas fazem a mesma rua${onde ? " (" + onde + ")" : ""}: dá para tirar 1`,
        resumo: `A <b>${esc(saida.r.linha)}</b> pode deixar de passar nesse trecho de ${km} km. As ~${nPes(saida.d)} que ela pega ali embarcam nas outras rotas que já passam na mesma rua.`,
        passos: [
          `Nesse trecho${onde ? " de <b>" + esc(onde) + "</b>" : ""} (${km} km, ${rs[0].sentido.toLowerCase()}) passam ${coletam} rotas pegando gente: ` +
            rs.map((r, i) => dem[i] >= 1 ? `${esc(r.linha)} ~${fmt(dem[i])}/dia` : null).filter(Boolean).join(" · ") + ".",
          `A <b>${esc(saida.r.linha)}</b> é a que menos pega ali (~${fmt(saida.d)}/dia).`,
          `${lista(ficam.map(r => `<b>${esc(r.linha)}</b> (${vagasTxt(r)})`))} já passa${ficam.length > 1 ? "m" : ""} na mesma rua e cabe${ficam.length > 1 ? "m" : ""} essas pessoas.`,
          `Resultado: ${coletam - 1} rota${coletam - 1 > 1 ? "s" : ""} nesse trecho em vez de ${coletam}, e a ${esc(saida.r.linha)} encurta o caminho.`],
        pessoas: [{ rotulo: `Quem a ${saida.r.linha} pega nesse trecho`, rt: saida.r.id, pontos: noTrecho[saida.i].map(e => [e.lat, e.lon]) }],
        destaques: [...segPerto(saida.r, t.pts, 60).map(pts => ({ pts, papel: "sai" })), ...ficam.flatMap(r => segPerto(r, t.pts, 60).map(pts => ({ pts, papel: "recebe" })))],
        setas: noTrecho[saida.i].map(e => { const alvoR = ficam.slice().sort((x, y) => (proj(x, e.lat, e.lon) || { d: 1e9 }).d - (proj(y, e.lat, e.lon) || { d: 1e9 }).d)[0]; return alvoR && seta(e.snap || [e.lat, e.lon], alvoR); }).filter(x => x && dist(x.de, x.para) > 15) });
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
          const cobreFim = {};
          for (const e of fim) for (const { rt: o, d } of perto(e.lat, e.lon, alvo)) {
            const c = cobreFim[o.id] || (cobreFim[o.id] = { o, n: 0, d: 1e9 }); c.n += e.depois; c.d = Math.min(c.d, d);
          }
          const fimOp = Object.values(cobreFim).sort((a, b) => Math.min(b.n, b.o.vagas) - Math.min(a.n, a.o.vagas) || a.d - b.d);
          let acc = 0; const comeco = [];
          for (const e of ini) { if (acc >= excesso) break; comeco.push(e); acc += e.dia; }
          const cobreIni = {};
          for (const e of comeco) for (const { rt: o, d } of perto(e.lat, e.lon, alvo)) {
            const c = cobreIni[o.id] || (cobreIni[o.id] = { o, n: 0, d: 1e9 }); c.n += e.dia; c.d = Math.min(c.d, d);
          }
          const iniOp = Object.values(cobreIni).sort((a, b) => Math.min(b.n, b.o.vagas) - Math.min(a.n, a.o.vagas) || a.d - b.d);
          const parIni = comeco.length ? paradaPerto(rt, comeco[0].lat, comeco[0].lon) : null;
          const a = fimOp[0], b = iniOp[0], papel = {};
          if (a) papel[a.o.id] = "recebe"; if (b && !papel[b.o.id]) papel[b.o.id] = "recebe2";
          const passos = [`O ônibus da <b>${esc(rt.linha)}</b> já está com ${cap} pessoas quando chega${rua(par) ? " em <b>" + esc(rua(par)) + "</b>" : " no fim do caminho"}${par && par.horario ? " (~" + par.horario + ")" : ""}, e ainda entram ~${nPes(excesso)} por dia dali em diante.`];
          if (a) passos.push(`<b>Opção 1 · outra rota pega o fim:</b> a <b>${esc(a.o.linha)}</b> passa a ${a.d} m desse trecho e tem ${vagasTxt(a.o)}. As ~${nPes(Math.min(excesso, a.o.vagas))} do fim passam a pegar a ${esc(a.o.linha)}.`);
          if (b) passos.push(`<b>Opção ${a ? 2 : 1} · outra rota pega o começo:</b> o começo da ${esc(rt.linha)}${rua(parIni) ? " (" + esc(rua(parIni)) + ")" : ""}, ~${nPes(acc)}/dia, fica a ${b.d} m da <b>${esc(b.o.linha)}</b>, que tem ${vagasTxt(b.o)}. Se essas pessoas forem para a ${esc(b.o.linha)}, a ${esc(rt.linha)} chega no fim com lugar para quem está sobrando.`);
          if (!a && !b) passos.push(`Nenhuma rota do mesmo grupo com vaga passa a até ${raio} m do fim nem do começo: precisa de ônibus extra ou dividir a rota.`);
          const pessoas = [];
          if (a || !b) pessoas.push({ rotulo: "Quem embarca no fim (depois do " + cap + "º)", rt: rt.id, pontos: fim.map(e => [e.lat, e.lon]) });
          if (b) pessoas.push({ rotulo: "Quem embarca no começo", rt: rt.id, pontos: comeco.map(e => [e.lat, e.lon]) });
          sug.push({ tipo: "LOTA_FIM", peso: 50 + excesso, sentido: rt.sentido, grupo: rt.grupo, turno: rt.turno,
            rotas: [rt.id, ...(a ? [a.o.id] : []), ...(b && b.o !== (a && a.o) ? [b.o.id] : [])], papel: { ...papel, [rt.id]: "cheia" },
            centro: [fim[0].lat, fim[0].lon], pontosFim: fim.map(e => [e.lat, e.lon]), pontosIni: comeco.map(e => [e.lat, e.lon]), principal: rt.id,
            titulo: `${rt.linha} lota no fim do caminho`,
            resumo: a ? `Passar as ~${nPes(Math.min(excesso, a.o.vagas))} do fim para a <b>${esc(a.o.linha)}</b>${b ? `, ou passar o começo para a <b>${esc(b.o.linha)}</b>` : ""}.`
                  : b ? `Passar o começo da rota para a <b>${esc(b.o.linha)}</b> para sobrar lugar no fim.` : `Sem rota com vaga por perto: ônibus extra ou dividir a rota.`,
            passos, pessoas,
            destaques: [{ pts: rt.dens.filter(q => q.s >= fim[0].s - 50 && q.s <= fim[fim.length - 1].s + 50).map(q => q.p), papel: "cheia" },
              ...(comeco.length ? [{ pts: rt.dens.filter(q => q.s >= comeco[0].s - 50 && q.s <= comeco[comeco.length - 1].s + 50).map(q => q.p), papel: "cheia" }] : []),
              ...(a ? segPerto(a.o, fim.map(e => [e.lat, e.lon]), raio).map(pts => ({ pts, papel: "recebe" })) : []),
              ...(b ? segPerto(b.o, comeco.map(e => [e.lat, e.lon]), raio).map(pts => ({ pts, papel: papel[b.o.id] })) : [])],
            setas: [...(a ? fim.map(e => seta(e.snap, a.o)) : []), ...(b ? comeco.map(e => seta(e.snap, b.o)) : [])].filter(x => x && dist(x.de, x.para) > 15) });
        }
      }
      // mover: pontos da rota cheia perto do caminho de outra com vaga
      const sobra = Math.max(Math.ceil(rt.carga - cap), Math.ceil(excesso));
      if (sobra <= 0) continue;
      const mov = {};
      for (const e of rt.emb) {
        if (e.dia < 0.3) continue;
        for (const { rt: o, d } of perto(e.lat, e.lon, alvo)) {
          const m = mov[o.id] || (mov[o.id] = { o, n: 0, pts: [], d: 1e9, dmax: 0 }); m.n += e.dia; m.pts.push([e.lat, e.lon, e.dia, d]); m.d = Math.min(m.d, d); m.dmax = Math.max(m.dmax, d);
        }
      }
      const ops = Object.values(mov).filter(m => m.n >= 0.5).sort((a, b) => Math.min(b.n, b.o.vagas) - Math.min(a.n, a.o.vagas) || a.d - b.d).slice(0, 3);
      if (!ops.length) continue;
      const papel = { [rt.id]: "cheia" }; ops.forEach((m, i) => papel[m.o.id] = i ? "recebe2" : "recebe");
      const m0 = ops[0], leva = Math.min(sobra, m0.o.vagas, Math.round(m0.n));
      const parM = (m) => { const p = m.pts.slice().sort((x, y) => y[2] - x[2])[0]; return rua(paradaPerto(rt, p[0], p[1]) || paradaPerto(m.o, p[0], p[1])); };
      sug.push({ tipo: "MOVER", peso: 30 + sobra, sentido: rt.sentido, grupo: rt.grupo, turno: rt.turno, rotas: [rt.id, ...ops.map(m => m.o.id)], papel, principal: rt.id,
        centro: m0.pts[0], pontos: ops.flatMap(m => m.pts.map(p => [p[0], p[1]])),
        titulo: `${rt.linha}: passar ${nPes(sobra)} para outra rota`,
        resumo: `Mover ~${nPes(leva)} da <b>${esc(rt.linha)}</b> para a <b>${esc(m0.o.linha)}</b>, que passa na mesma rua delas. A ${esc(rt.linha)} cai de ~${Math.round(rt.carga)} para ~${Math.round(rt.carga - leva)} por viagem.`,
        passos: [`A <b>${esc(rt.linha)}</b> leva em média <b>${fmt(rt.carga)}</b> por viagem (ideal ${cap}, ${lug} lugares): sobram ~${nPes(sobra)}.`,
          ...ops.map((m, i) => `<b>Opção ${i + 1} · ${esc(m.o.linha)}</b> (${vagasTxt(m.o)}): ~${nPes(m.n)} da ${esc(rt.linha)} embarcam a no máximo ${m.dmax} m do caminho dela${parM(m) ? ", perto de " + esc(parM(m)) : ""}. Cabem ${Math.min(Math.round(m.n), m.o.vagas)}.`)],
        pessoas: ops.map((m, i) => ({ rotulo: `Opção ${i + 1}: quem pode ir para a ${m.o.linha}`, rt: rt.id, pontos: m.pts.map(p => [p[0], p[1]]) })),
        // opção 1 desenhada por último (fica por cima); setas só da opção 1 para não poluir
        destaques: ops.map((m, i) => [m, i]).reverse().flatMap(([m, i]) => [...segPerto(rt, m.pts, 120).map(pts => ({ pts, papel: "cheia" })), ...segPerto(m.o, m.pts, raio).map(pts => ({ pts, papel: i ? "recebe2" : "recebe" }))]),
        setas: ops.slice(0, 1).flatMap(m => m.pts.map(p => { const e = rt.emb.find(x => x.lat === p[0] && x.lon === p[1]); return seta(e && e.snap || p, m.o); })).filter(x => x && dist(x.de, x.para) > 15) });
    }
    sug.sort((a, b) => b.peso - a.peso);
    return { rotas, porId, sug, garagens, ultimaColeta: ult ? new Date(ult) : null };
  }
  const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const fmt = n => (+n).toLocaleString("pt-BR", { maximumFractionDigits: 1 });
  const api = { analisar, norm, solta, densifica, dist, turnoDe, naGaragem };
  if (typeof module !== "undefined") module.exports = api; else root.Otim = api;
})(typeof window !== "undefined" ? window : globalThis);
