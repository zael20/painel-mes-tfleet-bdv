// ============================================================================
// Monitor Frota — "Montar alertas de uso de roteador" — RESUMO DIARIO
// Roda 1x por dia (agendar em "Todo dia no horario"). Pega todos os usos de
// roteador recebidos nas ultimas 24 h e devolve UM e-mail so com o resumo:
// { to, subject, html, eventId }. Sem uso no dia, manda "nenhum uso" (serve
// tambem de sinal de que o servidor esta vivo).
// eventId = -1 de proposito: o no "Marcar enviado" roda sem marcar nada
// (o resumo usa a janela de 24 h, nao depende de alert_sent).
// ============================================================================

const cfg = $('⚙️ CONFIG').first().json;
const SB  = String(cfg.supabaseUrl || '').replace(/\/+$/, '');
const KEY = String(cfg.supabaseServiceKey || '');
const TF_ACESSO = String(cfg.tfleetAcesso || '');
const TF_TOKEN  = String(cfg.tfleetToken  || '');
const JANELA_H = Number(cfg.resumoHoras || 24); // janela do resumo (horas)
const MIN_MOVE_M   = Number(cfg.minMoveMeters   || 150);

const H = { apikey: KEY, Authorization: 'Bearer ' + KEY };
const http = (opts) => this.helpers.httpRequest(opts);
const sbGet = (path) => http({ method: 'GET', url: SB + '/rest/v1/' + path, headers: H, json: true });

// ---- helpers de data (celular grava UTC; mostramos horario de Belem, UTC-3) ----
const p2 = (n) => String(n).padStart(2, '0');
const fmtBelem = (iso) => {
  const d = new Date(Date.parse(iso) - 3 * 3600000);
  return `${p2(d.getUTCDate())}/${p2(d.getUTCMonth() + 1)} ${p2(d.getUTCHours())}:${p2(d.getUTCMinutes())}`;
};
const dur = (ms) => {
  const min = Math.round(ms / 60000);
  const h = Math.floor(min / 60), m = min % 60;
  return h > 0 ? `${h}h ${m}min` : `${m}min`;
};
const hav = (a, b) => {
  const R = 6371000, tr = (x) => x * Math.PI / 180;
  const dLat = tr(b.lat - a.lat), dLon = tr(b.lon - a.lon);
  const s = Math.sin(dLat / 2) ** 2 + Math.cos(tr(a.lat)) * Math.cos(tr(b.lat)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(s));
};
const sampleN = (arr, n) => {
  if (arr.length <= n) return arr;
  const out = [], step = (arr.length - 1) / (n - 1);
  for (let i = 0; i < n; i++) out.push(arr[Math.round(i * step)]);
  return out;
};

// ---- 1) config da frota (liga/desliga, consumo minimo, destinatarios) ----
let fleet = {};
try {
  const dc = await sbGet('device_config?device_id=eq.*&select=config');
  if (Array.isArray(dc) && dc[0] && dc[0].config) fleet = dc[0].config;
} catch (e) { /* segue com padrao */ }

if (!(fleet.email_alert_on === true || fleet.email_alert_on === 'true')) return [];
const to = String(fleet.email_alert_to || '').trim();
if (!to) return [];
const minMb      = Number(fleet.email_alert_min_mb || 0);
const minCurrent = Number(fleet.min_current_ma || 300);

// ---- 2) eventos de roteador DESLIGADO recebidos na janela (24 h) ----
// janela por received_at: rodando 1x por dia, cada evento entra em um resumo so
const agoraIso = new Date().toISOString();
const since = new Date(Date.now() - JANELA_H * 3600000).toISOString();
let offs = [];
try {
  offs = await sbGet(
    'events?type=eq.hotspot_desligado' +
    '&received_at=gte.' + encodeURIComponent(since) +
    '&order=ts.asc&select=id,device_id,device_name,ts,detail'
  );
} catch (e) { throw new Error('Falha ao ler eventos do Supabase: ' + (e.message || e)); }
if (!Array.isArray(offs)) offs = [];

// ---- 3) viagens do dia (uma vez so, pra sugerir motorista) ----
let trips = [];
if (offs.length) try {
  const r = await http({
    method: 'POST',
    url: 'https://indicadores.tfleet.com.br/api/service-import/BdvCompletoHoje',
    headers: { 'Content-Type': 'application/json' },
    body: { acesso: TF_ACESSO, token: TF_TOKEN },
    json: true,
  });
  trips = Array.isArray(r) ? r : (r.data || r.result || r.viagens || r.dados || []);
  if (!Array.isArray(trips)) trips = [];
} catch (e) { trips = []; }

// pega um campo tolerando variacoes de nome/caixa
const pick = (o, names) => {
  for (const n of names) {
    for (const k of Object.keys(o)) {
      if (k.toLowerCase() === n.toLowerCase() && o[k] != null && o[k] !== '') return o[k];
    }
  }
  return null;
};
// combina data "dd/MM/yyyy" + hora LOCAL "HH:mm:ss" (Belem, UTC-3) em epoch ms (UTC)
const localToMs = (dateStr, timeStr) => {
  const dm = String(dateStr || '').match(/(\d{2})\/(\d{2})\/(\d{4})/);
  if (!dm) return NaN;
  const tm = String(timeStr || '').match(/(\d{1,2}):(\d{2})(?::(\d{2}))?/);
  const hh = tm ? +tm[1] : 0, mi = tm ? +tm[2] : 0, ss = tm && tm[3] ? +tm[3] : 0;
  return Date.UTC(+dm[3], +dm[2] - 1, +dm[1], hh + 3, mi, ss); // +3 = Belem -> UTC
};
// compara frota tolerando texto/numero ("39" == 39 == "Onibus 39"? -> por digito)
const sameFrota = (a, b) => {
  const na = String(a || '').trim(), nb = String(b || '').trim();
  if (na && na === nb) return true;
  const ia = parseInt(na, 10), ib = parseInt(nb, 10);
  return isFinite(ia) && isFinite(ib) && ia === ib;
};
// escapa texto que vai pro HTML do e-mail (nomes, linha com "&", etc.)
const esc = (s) => String(s == null ? '' : s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

const usos = [];

for (const ev of offs) {
  try {
    const devId = ev.device_id;
    const devName = ev.device_name;
    const offTs = ev.ts;
    const detail = ev.detail || {};
    const mb = Number(detail.mb_usados);

    // criterio: tem que ter consumo registrado e >= minimo configurado
    if (!(isFinite(mb) && mb > 0)) continue;
    if (minMb > 0 && mb < minMb) continue;

    // acha o "ligado" correspondente (o ultimo antes do desligamento)
    let onTs = null;
    try {
      const lig = await sbGet(
        'events?device_id=eq.' + encodeURIComponent(devId) +
        '&type=eq.hotspot_ligado&ts=lt.' + encodeURIComponent(offTs) +
        '&order=ts.desc&limit=1&select=ts'
      );
      if (Array.isArray(lig) && lig[0]) onTs = lig[0].ts;
    } catch (e) { /* sem janela */ }

    const offMs = Date.parse(offTs);
    const onMs = onTs ? Date.parse(onTs) : NaN;

    // amostras COM localizacao dentro da janela (ligado -> desligado)
    let pts = [];
    if (onTs) {
      let sm = [];
      try {
        sm = await sbGet(
          'samples?device_id=eq.' + encodeURIComponent(devId) +
          '&ts=gte.' + encodeURIComponent(onTs) + '&ts=lte.' + encodeURIComponent(offTs) +
          '&lat=not.is.null&order=ts.asc&limit=3000' +
          '&select=ts,lat,lon,speed_kmh,plugged,current_ma'
        );
      } catch (e) { sm = []; }
      pts = (Array.isArray(sm) ? sm : []).map((s) => ({
        lat: Number(s.lat), lon: Number(s.lon), spd: Number(s.speed_kmh || 0),
        plugged: s.plugged === true, ma: Number(s.current_ma),
      })).filter((p) => isFinite(p.lat) && isFinite(p.lon));
    }

    // no resumo o uso entra mesmo sem localizacao (aparece "sem localizacao")
    let local = '<span style="color:#888;">sem localizacao</span>';
    let carga = '<span style="color:#888;">—</span>';
    if (pts.length) {
      let dist = 0;
      for (let i = 1; i < pts.length; i++) dist += hav(pts[i - 1], pts[i]);
      const maxSpd = pts.reduce((m, p) => Math.max(m, p.spd), 0);
      const moved = dist >= MIN_MOVE_M || maxSpd >= 5;
      const c = pts[Math.floor(pts.length / 2)];
      local = moved
        ? `<a href="https://www.google.com/maps/dir/${sampleN(pts, 10).map((p) => `${p.lat},${p.lon}`).join('/')}" style="color:#1677ff;">rota</a> · ${(dist / 1000).toFixed(1)} km`
        : `<a href="https://www.google.com/maps?q=${c.lat},${c.lon}" style="color:#1677ff;">parado</a>`;
      const chg = (p) => p.plugged && (!isFinite(p.ma) || p.ma >= minCurrent);
      const pct = Math.round(100 * pts.filter(chg).length / pts.length);
      carga = chg(pts[0]) ? `${pct}%` : `${pct}% <b style="color:#c62828;">(nao entrou carregando)</b>`;
    }

    // sugestao de motorista (SEMPRE como possibilidade; nunca definitivo)
    const frota = String(devName || '').trim();
    let motorista = '<span style="color:#888;">sem viagem no horario</span>';
    if (onTs) {
      const cand = trips.filter((t) => sameFrota(pick(t, ['frota', 'Frota', 'numero', 'veiculo']), frota));
      let best = null, bestOv = 0;
      for (const t of cand) {
        let sMs = localToMs(pick(t, ['datasaida', 'dataSaida']), pick(t, ['Hrsaida', 'hrsaida', 'HrSaida']));
        if (isNaN(sMs)) sMs = Date.parse(pick(t, ['data']) || '');
        let eMs = localToMs(pick(t, ['datachegada', 'dataChegada']), pick(t, ['hrchegada', 'Hrchegada', 'HrChegada']));
        if (isNaN(eMs)) eMs = Date.now();
        if (isNaN(sMs)) continue;
        if (eMs < sMs) eMs = sMs + 3600000;
        const ov = Math.min(offMs, eMs) - Math.max(onMs, sMs);
        if (ov > 0 && ov > bestOv) { bestOv = ov; best = t; }
      }
      if (best) {
        const mot = pick(best, ['motorista', 'Motorista', 'nome', 'condutor']);
        const linha = pick(best, ['linha', 'Linha', 'rota']);
        motorista = (mot ? esc(mot) : 'nao informado') + (linha ? ` <span style="color:#888;">(${esc(linha)})</span>` : '') + ' <span style="color:#ad6800;">?</span>';
      }
    }

    usos.push({
      carro: frota || devId, mb, offMs,
      periodo: onTs ? `${fmtBelem(onTs)} → ${fmtBelem(offTs).slice(6)}` : `ate ${fmtBelem(offTs)}`,
      duracao: onTs ? dur(offMs - onMs) : '—',
      local, carga, motorista,
    });
  } catch (e) {
    // um evento com problema nao derruba os outros
  }
}

// ---- 4) monta o e-mail unico ----
const hoje = fmtBelem(agoraIso).slice(0, 5);
const fmtMb = (v) => (Math.round(v * 10) / 10).toLocaleString('pt-BR');
const totalMb = usos.reduce((s, u) => s + u.mb, 0);
const carros = [...new Set(usos.map((u) => u.carro))];
const td = 'padding:8px 6px;border-top:1px solid #eee;vertical-align:top;';

// ranking por carro
const porCarro = carros.map((c) => {
  const us = usos.filter((u) => u.carro === c);
  return { c, n: us.length, mb: us.reduce((s, u) => s + u.mb, 0) };
}).sort((a, b) => b.mb - a.mb);

const linhas = usos.map((u) =>
  `<tr><td style="${td}"><b>${esc(u.carro)}</b></td><td style="${td}">${u.periodo}<br><span style="color:#888;">${u.duracao}</span></td>` +
  `<td style="${td}"><b>${fmtMb(u.mb)}</b></td><td style="${td}">${u.local}</td><td style="${td}">${u.carga}</td><td style="${td}">${u.motorista}</td></tr>`).join('');

const corpo = usos.length === 0
  ? `<p style="font-size:15px;">Nenhum uso de roteador nas ultimas ${JANELA_H} h. 👍</p>`
  : `<table style="width:100%;border-collapse:collapse;font-size:14px;margin-bottom:16px;">
       <tr><td style="padding:4px 0;color:#555;width:170px;">Usos no periodo</td><td><b>${usos.length}</b></td></tr>
       <tr><td style="padding:4px 0;color:#555;">Carros</td><td><b>${carros.length}</b> (${porCarro.map((p) => `${esc(p.c)}: ${fmtMb(p.mb)} MB`).join(' · ')})</td></tr>
       <tr><td style="padding:4px 0;color:#555;">Consumo total</td><td><b>${fmtMb(totalMb)} MB</b></td></tr>
     </table>
     <table style="width:100%;border-collapse:collapse;font-size:13px;">
       <tr style="background:#f5f7fa;text-align:left;"><th style="padding:8px 6px;">Carro</th><th style="padding:8px 6px;">Periodo</th><th style="padding:8px 6px;">MB</th><th style="padding:8px 6px;">Local</th><th style="padding:8px 6px;">Carga</th><th style="padding:8px 6px;">Motorista</th></tr>
       ${linhas}
     </table>
     <p style="font-size:12px;color:#8c6d3f;margin-top:12px;">Motorista com "?" e apenas sugestao pelo cruzamento de horario com as viagens do dia; nao confirma quem ligou o roteador.</p>`;

const subject = usos.length
  ? `📶 Resumo do roteador ${hoje} — ${usos.length} uso(s), ${carros.length} carro(s), ${fmtMb(totalMb)} MB`
  : `📶 Resumo do roteador ${hoje} — nenhum uso`;

const html =
`<div style="font-family:Arial,Helvetica,sans-serif;max-width:760px;margin:auto;color:#222;">
  <div style="background:#1677ff;color:#fff;padding:16px 20px;border-radius:10px 10px 0 0;">
    <div style="font-size:18px;font-weight:700;">Resumo diario de uso de roteador</div>
    <div style="font-size:14px;opacity:.9;">${fmtBelem(since)} → ${fmtBelem(agoraIso)} (horario de Belem)</div>
  </div>
  <div style="border:1px solid #e5e5e5;border-top:none;border-radius:0 0 10px 10px;padding:18px 20px;">
    ${corpo}
    <div style="margin-top:16px;font-size:12px;color:#999;">Monitor Frota · resumo automatico do servidor da TV Box.</div>
  </div>
</div>`;

return [{ json: { to, subject, html, eventId: -1 } }];
