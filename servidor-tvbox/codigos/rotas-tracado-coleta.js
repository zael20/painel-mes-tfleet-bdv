// ============================================================================
// Monitor Frota — "Coletar traçado das rotas" (1x por dia, 05:30) — v1
// Le o mapa de roteirizacao da TFleet (link publico ger.jsp?token=...) e grava no Supabase,
// tabela rotas_tracado: traçado de ida/volta (simplificado), paradas com endereco/horario e
// quantos passageiros cadastrados. Nomes de passageiros NAO sao gravados.
// Rotas novas que entrarem no mapa (ex.: CT) entram sozinhas no dia seguinte.
// CONFIG: supabaseUrl, supabaseServiceKey, mapaLinks (um ou mais links ger.jsp?token=..., separados por espaco).
// ============================================================================
const cfg = $('⚙️ CONFIG').first().json;
const SB = String(cfg.supabaseUrl || '').replace(/\/+$/, '');
const KEY = String(cfg.supabaseServiceKey || '');
const LINKS = String(cfg.mapaLinks || '').split(/[\s,;]+/).filter(u => /^https:\/\/.+ger\.jsp\?token=/.test(u));
if (!SB || !KEY) throw new Error('Preencha supabaseUrl e supabaseServiceKey no CONFIG');
if (!LINKS.length) throw new Error('Preencha mapaLinks no CONFIG (link ger.jsp?token=... do mapa de roteirizacao)');
const UA = 'Mozilla/5.0 (X11; Linux aarch64) MonitorFrota/1.0';

const num = v => { const n = parseFloat(String(v ?? '').trim().replace(',', '.')); return isFinite(n) ? n : null; };
const R = 6371000, rad = x => x * Math.PI / 180;
const dist = (a, b) => 2 * R * Math.asin(Math.sqrt(Math.sin(rad(b[0] - a[0]) / 2) ** 2 + Math.cos(rad(a[0])) * Math.cos(rad(b[0])) * Math.sin(rad(b[1] - a[1]) / 2) ** 2));
const mediana = a => { const s = [...a].sort((x, y) => x - y); return s.length ? s[Math.floor(s.length / 2)] : null; };

// ponto -> [lat, lon] valido (o mapa tem ponto de passageiro geocodificado em outro estado; descarta longe da rota)
function limpa(lista) {
  const p = (lista || []).map(o => [num(o.latitude), num(o.longitude)]).filter(([a, b]) => a != null && b != null && a !== 0 && b !== 0);
  if (!p.length) return p;
  const c = [mediana(p.map(x => x[0])), mediana(p.map(x => x[1]))];
  return p.filter(x => dist(x, c) < 120000);
}
// Douglas-Peucker em metros (aprox. plana local) -> traçado leve para o painel
function simplifica(p, tol = 10) {
  if (p.length < 3) return p;
  const k = Math.cos(rad(p[0][0])) * 111320, M = 110540;
  const xy = p.map(([a, b]) => [b * k, a * M]);
  const keep = new Uint8Array(p.length); keep[0] = keep[p.length - 1] = 1;
  const pilha = [[0, p.length - 1]];
  while (pilha.length) {
    const [i, j] = pilha.pop(); let md = 0, mi = -1;
    const [x1, y1] = xy[i], [x2, y2] = xy[j], dx = x2 - x1, dy = y2 - y1, L = dx * dx + dy * dy;
    for (let t = i + 1; t < j; t++) {
      const [x, y] = xy[t];
      let u = L ? ((x - x1) * dx + (y - y1) * dy) / L : 0; u = Math.max(0, Math.min(1, u));
      const d = Math.hypot(x - (x1 + u * dx), y - (y1 + u * dy));
      if (d > md) { md = d; mi = t; }
    }
    if (md > tol) { keep[mi] = 1; pilha.push([i, mi], [mi, j]); }
  }
  return p.filter((_, i) => keep[i]).map(([a, b]) => [Math.round(a * 1e5) / 1e5, Math.round(b * 1e5) / 1e5]);
}
// remove salto absurdo (ponto de GPS perdido no meio do traçado)
function semSaltos(p) {
  const out = [];
  for (const x of p) { if (out.length && dist(out[out.length - 1], x) > 15000) continue; out.push(x); }
  return out;
}
const km = p => Math.round(p.reduce((t, x, i) => i ? t + dist(p[i - 1], x) : 0, 0) / 100) / 10;
const paradas = lista => (lista || []).map(o => ({ lat: num(o.latitude), lon: num(o.longitude), endereco: String(o.descricao || '').trim() || null, horario: /^\d{1,2}:\d{2}/.test(o.horario || '') ? o.horario.slice(0, 5) : null }))
  .filter(o => o.lat != null && o.lon != null && o.lat !== 0)
  .sort((a, b) => (a.horario || '99').localeCompare(b.horario || '99'));

const rows = [], erros = [], agora = new Date().toISOString();
for (const link of LINKS) {
  const base = link.replace(/ger\.jsp\?.*$/, '');
  const fonte = link.replace(/token=.*/, 'token=…');
  try {
    // 1) abre o mapa (cria a sessao do token)  2) pede todas as linhas, como o botao "Pesquisar" vazio
    const r1 = await this.helpers.httpRequest({ method: 'GET', url: link, headers: { 'User-Agent': UA }, returnFullResponse: true, json: false });
    let sc = r1.headers && (r1.headers['set-cookie'] || r1.headers['Set-Cookie']); if (sc && !Array.isArray(sc)) sc = [sc];
    const cookie = (sc || []).map(c => String(c).split(';')[0]).join('; ');
    const resp = await this.helpers.httpRequest({
      method: 'POST', url: base + 'ajax/ajax_gerencial_ger.jsp?action=searchline', json: false,
      headers: { 'User-Agent': UA, 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8', 'X-Requested-With': 'XMLHttpRequest', Referer: link, ...(cookie ? { Cookie: cookie } : {}) },
      body: 'param=&pesquisa=1&tracking=null&codigoModulo=',
    });
    const linhas = typeof resp === 'string' ? JSON.parse(resp.trim() || '[]') : resp;
    if (!Array.isArray(linhas) || !linhas.length) throw new Error('o mapa não devolveu linhas (link vencido?)');
    for (const l of linhas) {
      if (!l || l.codigoLinha == null || !l.linha) continue;
      for (const [sentido, chave, itin, tot] of [['IDA', 'ida', 'itinerarioIda', 'totalPass'], ['VOLTA', 'volta', 'itinerarioVolta', 'totalPassVolta']]) {
        const pts = simplifica(semSaltos(limpa(l[chave])));
        const par = paradas(l[itin]);
        if (pts.length < 2 && !par.length) continue;     // sentido sem traçado nem parada: nada a mostrar
        rows.push({ codigo_linha: l.codigoLinha, sentido, linha: String(l.linha).trim(), tipolinha: l.tipoLinha || null,
          pontos: pts, paradas: par, km: pts.length > 1 ? km(pts) : null, cadastrados: parseInt(l[tot], 10) || 0,
          fonte, atualizado_em: agora });
      }
    }
  } catch (e) { erros.push(fonte + ': ' + e.message); }
}
if (!rows.length) throw new Error('Nenhuma rota coletada. ' + erros.join(' | '));

const H = { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates,return=minimal' };
for (let i = 0; i < rows.length; i += 50)
  await this.helpers.httpRequest({ method: 'POST', url: SB + '/rest/v1/rotas_tracado?on_conflict=codigo_linha,sentido', headers: H, body: rows.slice(i, i + 50), json: true });

return [{ json: { rotas: new Set(rows.map(r => r.codigo_linha)).size, sentidos: rows.length,
  com_tracado: rows.filter(r => r.pontos.length > 1).length, pontos: rows.reduce((t, r) => t + r.pontos.length, 0), erros } }];
