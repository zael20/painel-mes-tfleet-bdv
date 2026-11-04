// ============================================================================
// Monitor Frota — "Montar alertas de uso de roteador"
// Roda uma vez por execucao. Le o Supabase, decide o que avisar, monta o e-mail
// (HTML bonitinho) e devolve 1 item por e-mail a enviar: { to, subject, html, eventId }.
// Se nao houver nada a avisar, devolve [] (os nos seguintes nem rodam).
// ============================================================================

const cfg = $('⚙️ CONFIG').first().json;
const SB  = String(cfg.supabaseUrl || '').replace(/\/+$/, '');
const KEY = String(cfg.supabaseServiceKey || '');
const TF_ACESSO = String(cfg.tfleetAcesso || '');
const TF_TOKEN  = String(cfg.tfleetToken  || '');
const LOOKBACK_MIN = Number(cfg.lookbackMinutes || 120);
const MIN_MOVE_M   = Number(cfg.minMoveMeters   || 150);
const MAPTILER_KEY = String(cfg.maptilerKey || 'G2MUHW7Q8hatR3VYbHUz');
// Rastreio de abertura do e-mail (imagem 1x1). Funcao do Supabase, slug bright-handler.
const ABERTURA_URL = String(cfg.aberturaUrl || 'https://orhuxmsrdnugpogvtnbg.supabase.co/functions/v1/bright-handler');

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

// ---- 2) eventos de roteador DESLIGADO, recentes e ainda nao avisados ----
const since = new Date(Date.now() - LOOKBACK_MIN * 60000).toISOString();
let offs = [];
try {
  offs = await sbGet(
    'events?type=eq.hotspot_desligado&alert_sent=is.null' +
    '&received_at=gte.' + encodeURIComponent(since) +
    '&order=ts.asc&select=id,device_id,device_name,ts,detail'
  );
} catch (e) { return []; }
if (!Array.isArray(offs) || offs.length === 0) return [];

// ---- 3) viagens do dia (uma vez so, pra sugerir motorista) ----
let trips = [];
try {
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

const out = [];

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
    if (!onTs) continue; // sem inicio nao da pra montar janela/rota

    const onMs = Date.parse(onTs), offMs = Date.parse(offTs);

    // amostras COM localizacao dentro da janela (ligado -> desligado)
    let sm = [];
    try {
      sm = await sbGet(
        'samples?device_id=eq.' + encodeURIComponent(devId) +
        '&ts=gte.' + encodeURIComponent(onTs) + '&ts=lte.' + encodeURIComponent(offTs) +
        '&lat=not.is.null&order=ts.asc&limit=3000' +
        '&select=ts,lat,lon,speed_kmh,plugged,current_ma'
      );
    } catch (e) { sm = []; }

    const pts = (Array.isArray(sm) ? sm : []).map((s) => ({
      lat: Number(s.lat), lon: Number(s.lon), spd: Number(s.speed_kmh || 0),
      plugged: s.plugged === true, ma: Number(s.current_ma),
    })).filter((p) => isFinite(p.lat) && isFinite(p.lon));

    if (pts.length === 0) continue; // criterio: precisa ter rota OU localizacao

    // parado x em movimento
    let dist = 0;
    for (let i = 1; i < pts.length; i++) dist += hav(pts[i - 1], pts[i]);
    const maxSpd = pts.reduce((m, p) => Math.max(m, p.spd), 0);
    const moved = dist >= MIN_MOVE_M || maxSpd >= 5;

    // carga durante a janela
    const chg = (p) => p.plugged && (!isFinite(p.ma) || p.ma >= minCurrent);
    const chargedPts = pts.filter(chg).length;
    const chargedPct = Math.round(100 * chargedPts / pts.length);
    const cameCharging = chg(pts[0]);

    // links (sempre funcionam, sem chave)
    const c = pts[Math.floor(pts.length / 2)];
    const linkFixo  = `https://www.google.com/maps?q=${c.lat},${c.lon}`;
    const linkRota  = 'https://www.google.com/maps/dir/' +
      sampleN(pts, 10).map((p) => `${p.lat},${p.lon}`).join('/');

    // sugestao de motorista (SEMPRE como possibilidade; nunca definitivo)
    const frota = String(devName || '').trim();
    let sugestao = '';
    let motoristaNome = null; // texto puro, vai para roteador_tratativas.motorista_sugerido
    const cand = trips.filter((t) => sameFrota(pick(t, ['frota', 'Frota', 'numero', 'veiculo']), frota));
    let best = null, bestOv = 0;
    for (const t of cand) {
      // saida: datasaida + Hrsaida (hora local); fallback no campo "data" (ISO UTC)
      let sMs = localToMs(pick(t, ['datasaida', 'dataSaida']), pick(t, ['Hrsaida', 'hrsaida', 'HrSaida']));
      if (isNaN(sMs)) sMs = Date.parse(pick(t, ['data']) || '');
      // chegada: datachegada + hrchegada (hora local); se vazio, viagem aberta -> agora
      let eMs = localToMs(pick(t, ['datachegada', 'dataChegada']), pick(t, ['hrchegada', 'Hrchegada', 'HrChegada']));
      const aberta = isNaN(eMs);           // viagem ainda sem finalizacao
      if (aberta) eMs = Date.now();
      if (isNaN(sMs)) continue;
      if (eMs < sMs) eMs = sMs + 3600000; // seguranca
      const ov = Math.min(offMs, eMs) - Math.max(onMs, sMs);
      if (ov > 0 && ov > bestOv) { bestOv = ov; best = { t, sMs, eMs, aberta }; }
    }
    if (best) {
      const mot = pick(best.t, ['motorista', 'Motorista', 'nome', 'condutor']);
      motoristaNome = mot ? String(mot) : 'nao informado';
      const linha = pick(best.t, ['linha', 'Linha', 'rota']);
      const tipo = pick(best.t, ['tipo', 'Tipo', 'sentido']);
      const quando = best.aberta
        ? `aberta desde ${fmtBelem(new Date(best.sMs).toISOString())} (ainda sem finalizacao)`
        : `no horario ${fmtBelem(new Date(best.sMs).toISOString())} – ${fmtBelem(new Date(best.eMs).toISOString())}`;
      const quem = mot ? `<b>${esc(mot)}</b>` : 'motorista nao informado na API';
      const extra = [linha ? `linha ${esc(linha)}` : '', tipo ? esc(tipo) : ''].filter(Boolean).join(' · ');
      sugestao =
        `<div style="margin-top:14px;padding:12px 14px;background:#fff7e6;border:1px solid #ffd591;border-radius:8px;">
           <div style="font-size:13px;color:#ad6800;font-weight:600;">Possivel responsavel (apenas sugestao)</div>
           <div style="font-size:14px;color:#613400;margin-top:4px;">
             ${quem} — viagem ${extra ? '(' + extra + ') ' : ''}${quando}, que coincide com o periodo do roteador.
           </div>
           <div style="font-size:12px;color:#8c6d3f;margin-top:6px;">
             Isto e uma possibilidade baseada no cruzamento de horarios; nao confirma quem ligou o roteador. Verificar.
           </div>
         </div>`;
    } else {
      sugestao =
        `<div style="margin-top:14px;padding:12px 14px;background:#f0f0f0;border:1px solid #d9d9d9;border-radius:8px;font-size:13px;color:#595959;">
           Nenhuma viagem do dia coincide com o horario do roteador — sem sugestao de motorista. Equipe pode investigar.
         </div>`;
    }

    // ---- monta o corpo ----
    const mbTxt = (Math.round(mb * 10) / 10).toLocaleString('pt-BR');
    const periodo = `${fmtBelem(onTs)} → ${fmtBelem(offTs)}`;
    const duracao = dur(offMs - onMs);
    const carga = `${chargedPct}% do tempo carregando bem` +
      (cameCharging ? ' · entrou carregando' : ' · <b>nao estava carregando no inicio</b>');

    const locBloco = moved
      ? `<tr><td style="padding:6px 0;color:#555;">Trajeto</td>
             <td style="padding:6px 0;"><a href="${linkRota}" style="color:#1677ff;">Ver rota no mapa</a>
             — ${(dist / 1000).toFixed(1)} km percorridos</td></tr>`
      : `<tr><td style="padding:6px 0;color:#555;">Local</td>
             <td style="padding:6px 0;">Ficou <b>parado</b> — <a href="${linkFixo}" style="color:#1677ff;">ver no mapa</a>
             (${duracao} no mesmo ponto)</td></tr>`;

    // imagem 1x1 no fim do e-mail: quando ele carrega, a funcao grava email_aberto_em
    const pixel = `<img src="${ABERTURA_URL}?ids=${ev.id}" width="1" height="1" alt="" style="display:block;border:0;">`;

    const subject = `🚐 Roteador usado — carro ${frota || devId} — ${mbTxt} MB`;
    const html =
`<div style="font-family:Arial,Helvetica,sans-serif;max-width:660px;margin:auto;color:#222;">
  <div style="background:#1677ff;color:#fff;padding:16px 20px;border-radius:10px 10px 0 0;">
    <div style="font-size:18px;font-weight:700;">Uso de roteador detectado</div>
    <div style="font-size:14px;opacity:.9;">Carro ${frota || devId} · ${fmtBelem(offTs)}</div>
  </div>
  <div style="border:1px solid #e5e5e5;border-top:none;border-radius:0 0 10px 10px;padding:18px 20px;">
    <table style="width:100%;border-collapse:collapse;font-size:14px;">
      <tr><td style="padding:6px 0;color:#555;width:120px;">Carro</td><td style="padding:6px 0;"><b>${frota || devId}</b></td></tr>
      <tr><td style="padding:6px 0;color:#555;">Consumo</td><td style="padding:6px 0;"><b>${mbTxt} MB</b> pelo roteador</td></tr>
      <tr><td style="padding:6px 0;color:#555;">Periodo</td><td style="padding:6px 0;">${periodo} <span style="color:#888;">(${duracao})</span></td></tr>
      <tr><td style="padding:6px 0;color:#555;">Carga</td><td style="padding:6px 0;">${carga}</td></tr>
      ${locBloco}
    </table>
    <div style="margin-top:18px;">
      <a href="${moved ? linkRota : linkFixo}" style="display:inline-block;background:#1677ff;color:#fff;text-decoration:none;padding:12px 22px;border-radius:8px;font-weight:600;font-size:14px;">
        📍 ${moved ? 'Abrir rota no mapa' : 'Abrir local no mapa'}
      </a>
    </div>
    ${sugestao}
    <div style="margin-top:16px;font-size:12px;color:#999;">
      Monitor Frota · aviso automatico.
    </div>
  </div>
  ${pixel}
</div>`;

    // registro do uso: carro, motorista sugerido e envio (alimenta a aba "Uso no roteador" do painel)
    // merge: cria a linha ou atualiza so essas colunas; token e tratativa ficam como estao
    try {
      await http({ method: 'POST', url: SB + '/rest/v1/roteador_tratativas?on_conflict=event_id', json: true,
        headers: { ...H, 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates,return=minimal' },
        body: [{ event_id: ev.id, carro: frota || devId, motorista_sugerido: motoristaNome, email_enviado_em: new Date().toISOString() }] });
    } catch (e) { /* sem o SQL roteador-registros: o e-mail sai do mesmo jeito */ }

    out.push({ json: { to, subject, html, eventId: ev.id } });
  } catch (e) {
    // um evento com problema nao derruba os outros
  }
}

return out;
