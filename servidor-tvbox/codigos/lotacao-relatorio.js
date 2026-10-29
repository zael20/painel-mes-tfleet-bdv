// ============================================================================
// Monitor Frota — "Montar e-mails" (2x por dia: 8h15 e 18h15) — v5
// Agendar com cron "15 8,18 * * *" (horario de Belem).
//  - Manha (antes do meio-dia): e-mail de ocupacao + fora de rota com tudo que chegou ate ~8h.
//  - Tarde: so fora de rota NOVO (quem ja foi avisado de manha nao repete; se a pessoa
//    voltou numa OUTRA linha, entra so essa volta). Ocupacao nao repete a tarde.
//  - Repeticao e controlada no Supabase (criar_consultas: mesma pessoa + linha nao repete em 14 dias).
// Devolve 1 item por e-mail: { to, cc, replyTo, subject, html, consultaIds }.
//  E-mail 1 "Ocupação dos ônibus" (para voce, e-mail Hydro): rotas lotando / com previsao nas ultimas 2 semanas,
//           cadastro INATIVO embarcando e respostas dos supervisores.
//  E-mail 2 "Análise de passageiros fora de rota" (para o gestor): passageiro embarcando ha varios dias numa
//           rota diferente da cadastrada, com botoes de resposta pronta (pagina resposta.html).
//           O gestor de cada pessoa vem do Supabase (funcao consultas_destino): e-mail na linha da pessoa >
//           empresa > base de gestores por centro de custo > GA > GG. Mudar a regra la nao exige mexer aqui.
//           Sem gestor, ou com enviarGestores = false, vai para voce (mostrando para quem iria).
// Nada a avisar -> [] (nao manda e-mail). O no "Marcar enviadas" grava enviado_para depois do envio.
// ============================================================================
const cfg = $('⚙️ CONFIG').first().json;
const HYDRO = String(cfg.emailTo || '').trim();
const CC_EXTRA = String(cfg.emailCc || '').trim();
const SB = String(cfg.supabaseUrl || '').replace(/\/+$/, '');
const KEY = String(cfg.supabaseServiceKey || '');
const DIAS = Number(cfg.dias || 14), CAP = Number(cfg.capacidade || 40), LUG = Number(cfg.lugares || 45);
const MIN_DIAS = Number(cfg.minDiasRecorrente || 3), RAIO = Number(cfg.raioMetros || 400);
const TIPOS = String(cfg.tiposConsulta || 'ITINERANTE,REGULAR');
const MAX_ROTAS = Number(cfg.maxRotasEmail || 8);
const PAINEL = String(cfg.painelUrl || 'https://zael20.github.io/painel-mes-tfleet-bdv/lotacao.html');
const RESP = String(cfg.respostaUrl || 'https://zael20.github.io/painel-mes-tfleet-bdv/resposta.html');
const ENVIAR_GESTORES = cfg.enviarGestores === true || cfg.enviarGestores === 'true';

const H = { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json' };
const rpc = (fn, body) => this.helpers.httpRequest({ method: 'POST', url: SB + '/rest/v1/rpc/' + fn, headers: H, body, json: true });
const get = (path) => this.helpers.httpRequest({ method: 'GET', url: SB + '/rest/v1/' + path, headers: H, json: true });

const [rotas, diasRows, alts, resumo, inativos, monitRows] = await Promise.all([
  rpc('lotacao_rotas', { dias: DIAS, capacidade: CAP, lugares: LUG }),
  rpc('lotacao_dias', { dias: DIAS }),
  rpc('lotacao_alternativas', { dias: DIAS, capacidade: CAP, raio_m: RAIO }),
  rpc('fora_rota_resumo', { dias: DIAS, min_dias: MIN_DIAS }),
  rpc('passageiros_inativos', { dias: 7 }).catch(() => []),
  get('rotas_monitoradas?select=linha').catch(() => []),
]);
// cria as consultas novas e pega todas que ainda nao foram enviadas (ultimos 7 dias)
await rpc('criar_consultas', { dias: 7, min_dias: MIN_DIAS, tipos: TIPOS, intervalo_dias: 14 });
const desde7 = new Date(Date.now() - 7 * 864e5).toISOString();
const pendentes = await get(`consultas?enviado_para=is.null&criado_em=gte.${desde7}&order=ga.asc,nome.asc`);
const desde1 = new Date(Date.now() - 26 * 3600e3).toISOString();
const respostas = await get(`consultas?respondido_em=gte.${desde1}&order=respondido_em.desc`);
const destinos = pendentes.length ? await rpc('consultas_destino', { p_ids: pendentes.map(c => c.id) }).catch(() => []) : [];
const DEST = Object.fromEntries(destinos.map(d => [d.id, d]));

// ---- helpers
const monit = monitRows.map(m => m.linha);
const naLista = l => !monit.length || monit.includes(l);
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const f0 = n => n == null ? '–' : Math.round(Number(n)).toLocaleString('pt-BR');
const ddmm = d => String(d).slice(8, 10) + '/' + String(d).slice(5, 7);
const hoje = new Date(Date.now() - 3 * 3600e3).toISOString().slice(0, 10).split('-').reverse().join('/');
const sem = t => String(t || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toUpperCase().replace(/\s*-\s*PASSAGEIRO\s*$/, '').trim();
// mesmo criterio do SQL grupo_linha(): CT + numero = terceiros; ADM; TURNO
const grupo = t => { const n = sem(t); return /^CT\s*-?\s*\d/.test(n) ? 'CT' : /(^|[^A-Z])ADM([^A-Z]|$)/.test(n) ? 'ADM' : /TURNO/.test(n) ? 'TURNO' : null; };
const NOME_GRUPO = { CT: 'terceiros (CT)', ADM: 'ADM', TURNO: 'turno' };
const FONT = 'font-family:Segoe UI,Arial,sans-serif;';
const TIPO = {
  'LOTACAO RECORRENTE':  { cor: '#c62828', fundo: '#fdecea', rot: 'LOTANDO' },
  'LOTACAO FREQUENTE':   { cor: '#b26a00', fundo: '#fff4e0', rot: 'ATENÇÃO' },
  'PREVISAO DE LOTACAO': { cor: '#1565c0', fundo: '#e8f1fb', rot: 'PREVISÃO' },
};
const RESPOSTAS = [
  ['TREINAMENTO', 'Treinamento / temporário'],
  ['MUDOU_ENDERECO', 'Mudou de endereço'],
  ['MUDOU_TURNO', 'Mudou de turno / escala'],
  ['COBERTURA', 'Cobertura (férias / folga)'],
  ['NAO_SEI', 'Não sei, vou verificar'],
  ['OUTRO', 'Outro motivo (escrever)'],
];
const NOME_RESP = Object.fromEntries(RESPOSTAS);
// gestor de uma consulta (calculado no Supabase); sem gestor = null
function gestorDe(c) {
  const d = DEST[c.id]; c._empresa = d && d.empresa;
  return d && d.email ? { email: d.email, nome: d.nome, origem: d.origem } : null;
}

function moldura(titulo, sub, corpo) {
  return `<div style="${FONT}background:#eef1f4;padding:16px 0">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:640px;margin:0 auto;background:#ffffff;border-radius:10px;overflow:hidden">
    <tr><td style="background:#17212b;padding:16px 20px;color:#ffffff">
      <div style="font-size:12px;color:#93a1ae;letter-spacing:.06em">MONITOR FROTA · TRANSPORTE</div>
      <div style="font-size:20px;font-weight:700;margin-top:2px">${titulo}</div>
      <div style="font-size:13px;color:#c9d3dc;margin-top:2px">${sub}</div></td></tr>
    <tr><td style="padding:16px 20px">${corpo}</td></tr>
    <tr><td style="padding:12px 20px;border-top:1px solid #e3e8ed;font-size:12px;color:#5b6875">
      Ideal ${CAP} passageiros por ônibus (${LUG} lugares). Dados da API TFleet. Mensagem automática.</td></tr>
  </table></div>`;
}
const botao = (href, txt, cor = '#0d6c8c') =>
  `<a href="${href}" style="display:inline-block;background:${cor};color:#ffffff;text-decoration:none;font-weight:600;font-size:13px;padding:9px 14px;border-radius:6px;margin:3px 4px 3px 0">${txt}</a>`;

// quadradinhos dos dias (vermelho > ideal, amarelo >= 90%, verde abaixo)
function quadrados(r) {
  const ds = diasRows.filter(d => d.linha === r.linha && d.tipo === r.tipo && d.faixa === r.faixa).slice(-10);
  if (!ds.length) return '';
  return '<table role="presentation" cellpadding="0" cellspacing="0" style="margin:8px 0 4px"><tr>' + ds.map(d => {
    const c = d.ocupacao > CAP ? ['#c62828', '#ffffff'] : d.ocupacao >= CAP * 0.9 ? ['#f5b301', '#17212b'] : ['#2e7d32', '#ffffff'];
    return `<td style="padding:0 3px 0 0"><div style="background:${c[0]};color:${c[1]};border-radius:5px;width:44px;text-align:center;padding:4px 0">
      <div style="font-size:15px;font-weight:700;line-height:1.1">${d.ocupacao}</div><div style="font-size:10px;opacity:.85">${ddmm(d.data_local)}</div></div></td>`;
  }).join('') + '</tr></table>';
}

function cartaoRota(r) {
  const t = TIPO[r.status];
  const al = alts.find(a => a.linha === r.linha && a.sentido === r.tipo);
  const rs = resumo.find(x => x.linha === r.linha && x.sentido === r.tipo);
  const linhaDias = r.viagens_acima > 0
    ? `Passou de ${CAP} em <b>${r.dias_acima} de ${r.dias_com_dado} dias</b> · máx ${r.maximo}`
    : `Ainda não passou de ${CAP}, mas está perto`;
  let extra = '';
  if (al) extra += `<div style="font-size:13px;margin-top:6px">🔁 <b>${esc(al.alternativa)}</b> (mesmo grupo) passa a ${al.distancia_m} m de um ponto desta rota, com ~${f0(al.alt_folga)} vagas (embarque ~${esc(al.alt_hora)}). <a href="https://www.google.com/maps?q=${al.ponto_lat},${al.ponto_lon}" style="color:#0d6c8c">Ver ponto</a></div>`;
  if (rs && rs.de_outra_linha_dia >= 1) extra += `<div style="font-size:13px;margin-top:4px">👥 ~${f0(rs.de_outra_linha_dia)} passageiro(s)/dia são cadastrados em outra rota${r.excedente > 0 && rs.de_outra_linha_dia >= r.excedente ? ': <b>regularizar esses já resolve</b>' : ''}.</div>`;
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 12px;border:1px solid #e3e8ed;border-left:5px solid ${t.cor};border-radius:8px">
  <tr><td style="padding:10px 12px">
    <span style="background:${t.fundo};color:${t.cor};font-size:11px;font-weight:700;letter-spacing:.05em;padding:2px 8px;border-radius:99px">${t.rot}</span>
    <div style="font-size:16px;font-weight:700;margin-top:6px;color:#17212b">${esc(r.linha)}</div>
    <div style="font-size:12px;color:#5b6875">${esc(r.tipo)} · ${r.ref === 'turno' ? 'turno' : 'saída'} ${esc(r.faixa)} · ônibus ${esc(r.frotas)}</div>
    <div style="font-size:14px;margin-top:6px;color:#17212b">Média <b style="font-size:18px">${f0(r.media_viagem)}</b> pessoas · ${linhaDias}</div>
    ${quadrados(r)}
    <div style="font-size:14px;margin-top:6px;color:#17212b">➜ <b>${esc(r.sugestao || '')}</b></div>${extra}
  </td></tr></table>`;
}

const out = [];

// ---------------- E-mail 1: lotacao (para voce) — so no envio da manha
const MANHA = new Date(Date.now() - 3 * 3600e3).getUTCHours() < 12;
const alerta = rotas.filter(r => TIPO[r.status] && naLista(r.linha));
const fIna = inativos.filter(p => naLista(p.linha));
if (MANHA && (alerta.length || fIna.length || respostas.length)) {
  const nL = alerta.filter(r => r.status === 'LOTACAO RECORRENTE').length;
  const nA = alerta.filter(r => r.status === 'LOTACAO FREQUENTE').length;
  const nP = alerta.filter(r => r.status === 'PREVISAO DE LOTACAO').length;
  const chip = (n, txt, cor) => n ? `<td style="padding:0 6px 0 0"><div style="background:${cor};color:#fff;border-radius:8px;padding:8px 12px;text-align:center">
      <div style="font-size:22px;font-weight:700;line-height:1">${n}</div><div style="font-size:11px">${txt}</div></div></td>` : '';
  let corpo = `<table role="presentation" cellpadding="0" cellspacing="0" style="margin-bottom:14px"><tr>${chip(nL, 'lotando', '#c62828')}${chip(nA, 'atenção', '#b26a00')}${chip(nP, 'previsão', '#1565c0')}${chip(fIna.length, 'inativo(s)', '#5b6875')}</tr></table>`;
  corpo += alerta.slice(0, MAX_ROTAS).map(cartaoRota).join('');
  if (alerta.length > MAX_ROTAS) corpo += `<p style="font-size:13px;color:#5b6875">+ ${alerta.length - MAX_ROTAS} rota(s) no painel.</p>`;
  if (fIna.length) corpo += `<div style="background:#fdecea;border-radius:8px;padding:10px 12px;margin:6px 0 12px;font-size:13px;color:#17212b">
      <b style="color:#c62828">Cadastro INATIVO embarcando</b> (últimos 7 dias)<br>` +
    fIna.map(p => `${esc(p.nome)} (${esc(p.matricula)}) · ${esc(p.linha)} · último ${ddmm(p.ultimo)}`).join('<br>') + '</div>';
  if (respostas.length) corpo += `<div style="background:#e8f5e9;border-radius:8px;padding:10px 12px;margin:6px 0 12px;font-size:13px;color:#17212b">
      <b style="color:#2e7d32">Respostas dos supervisores</b><br>` +
    respostas.map(c => `${esc(c.nome)} · ${esc(c.linha_usada)}: <b>${esc(NOME_RESP[c.resposta] || c.resposta)}</b>${c.comentario ? ' — "' + esc(c.comentario) + '"' : ''}`).join('<br>') + '</div>';
  corpo += `<div style="margin-top:6px">${botao(PAINEL, 'Abrir painel de lotação')}</div>`;
  const partes = [nL && `${nL} lotando`, nA && `${nA} em atenção`, nP && `${nP} com previsão`, fIna.length && `${fIna.length} inativo(s)`].filter(Boolean);
  out.push({ json: {
    to: HYDRO, cc: CC_EXTRA, replyTo: HYDRO, consultaIds: [],
    subject: `Ocupação dos ônibus ${hoje}: ${partes.join(', ') || 'respostas dos supervisores'}`,
    html: moldura('Ocupação dos ônibus', `${DIAS === 14 ? 'Últimas 2 semanas' : 'Últimos ' + DIAS + ' dias'} · ${hoje}${monit.length ? ' · só rotas monitoradas' : ''}`, corpo),
  }});
}

// ---------------- E-mail 2: passageiros fora de rota (um cartao por pessoa, mesmo que use mais de uma linha)
const porDestino = {};
for (const c of pendentes) {
  c._gestor = gestorDe(c);
  const g = ENVIAR_GESTORES ? c._gestor : null;
  const para = g ? g.email : HYDRO;
  (porDestino[para] = porDestino[para] || { g, itens: [] }).itens.push(c);
}
const chavePessoa = c => c.matricula ? 'M:' + String(c.matricula).trim() : 'N:' + String(c.nome || '').trim().toUpperCase();
const TIPO_COR = t => /ITINER/i.test(t) ? ['#fff4e0', '#b26a00'] : /INATIV/i.test(t) ? ['#fdecea', '#c62828'] : ['#e0eff4', '#0d6c8c'];
for (const [para, { g, itens }] of Object.entries(porDestino)) {
  const pessoas = {};
  for (const c of itens) (pessoas[chavePessoa(c)] = pessoas[chavePessoa(c)] || []).push(c);
  const lista = Object.values(pessoas);
  const aviso = g ? '' : `<div style="background:#fff4e0;border-radius:8px;padding:8px 12px;margin-bottom:12px;font-size:13px;color:#17212b">
     ${ENVIAR_GESTORES ? 'Sem gestor cadastrado no painel para estes colaboradores.' : 'Envio para gestores desligado: cada cartão mostra para quem iria.'} Este e-mail veio para você: encaminhe ao gestor ou responda pelos botões.</div>`;
  // faixa de cima: deixa claro, antes de tudo, por que a pessoa recebeu este e-mail
  const faixa = `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 14px;background:#b26a00;border-radius:8px"><tr><td style="padding:12px 14px;color:#fff">
      <div style="font-size:12px;font-weight:700;letter-spacing:.08em">PASSAGEIRO FORA DE ROTA · TRANSPORTE DE COLABORADORES</div>
      <div style="font-size:15px;margin-top:4px">${g && g.nome ? 'Olá, ' + esc(g.nome) + '. ' : ''}${lista.length === 1 ? 'Um colaborador da sua equipe está' : lista.length + ' colaboradores da sua equipe estão'} embarcando num ônibus <b>diferente da rota cadastrada</b> na TFleet.</div>
      <div style="font-size:13px;margin-top:6px;opacity:.95">Precisamos saber o motivo para manter os ônibus dentro da lotação e o cadastro certo. Toque numa resposta abaixo de cada nome: leva 10 segundos.</div>
    </td></tr></table>`;
  const cards = lista.map(cs => {
    const c = cs[0], base = `${RESP}?t=${c.token}&r=`;
    const gc = grupo(c.linha_cadastro), gus = [...new Set(cs.map(x => grupo(x.linha_usada)).filter(Boolean))];
    const gu = gus.find(x => x !== gc) || gus[0];
    const trocaGrupo = gc && gu && gc !== gu;
    // troca de grupo (ex.: turno -> ADM) sugere mudanca de turno/escala: essa resposta vem primeiro
    const ordem = trocaGrupo ? [RESPOSTAS[2], ...RESPOSTAS.filter((_, i) => i !== 2)] : RESPOSTAS;
    const [fundo, cor] = TIPO_COR(c.tipopassageiro || '');
    const linhas = cs.map(x => `<b>${esc(x.linha_usada)}</b> (${esc(x.sentido || '')}) · ${x.dias} dia(s), ${ddmm(x.primeiro)}${x.ultimo !== x.primeiro ? ' a ' + ddmm(x.ultimo) : ''}`).join('<br>');
    const extra = [c.matricula ? 'Matrícula ' + esc(c.matricula) : 'sem matrícula', c._empresa && esc(c._empresa), c.ga && esc(c.ga)].filter(Boolean).join(' · ');
    return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 12px;border:1px solid #e3e8ed;border-left:5px solid ${trocaGrupo ? '#b26a00' : '#0d6c8c'};border-radius:8px">
    <tr><td style="padding:10px 12px;color:#17212b">
      <span style="background:${fundo};color:${cor};font-size:12px;font-weight:700;padding:3px 10px;border-radius:99px;letter-spacing:.04em">${esc((c.tipopassageiro || 'FORA DE ROTA').toUpperCase())}</span>
      ${trocaGrupo ? ` <span style="background:#fff4e0;color:#b26a00;font-size:11px;font-weight:700;padding:3px 8px;border-radius:99px">POSSÍVEL MUDANÇA DE ${esc(NOME_GRUPO[gc]).toUpperCase()} PARA ${esc(NOME_GRUPO[gu]).toUpperCase()}</span>` : ''}
      <div style="font-size:16px;font-weight:700;margin-top:6px">${esc(c.nome)}</div>
      <div style="font-size:12px;color:#5b6875">${extra}</div>
      ${g ? '' : `<div style="font-size:12px;color:${c._gestor ? '#5b6875' : '#b26a00'}">${c._gestor ? `Gestor: ${esc(c._gestor.nome || '')} ${esc(c._gestor.email)} (via ${c._gestor.origem})` : 'Sem gestor cadastrado'}</div>`}
      <div style="font-size:14px;margin-top:8px">Embarcou em:<br>${linhas}<br>
        <span style="color:#5b6875">Rota cadastrada: ${esc(c.linha_cadastro ? String(c.linha_cadastro).replace(/\s*-\s*PASSAGEIRO\s*$/i, '') : 'nenhuma rota cadastrada na TFleet')}</span></div>
      <div style="font-size:14px;font-weight:600;margin:10px 0 4px">Por que está nessa rota?</div>
      ${ordem.map(([k, txt]) => botao(base + k, txt, k === 'OUTRO' ? '#5b6875' : '#0d6c8c')).join('')}
    </td></tr></table>`;
  }).join('');
  out.push({ json: {
    to: para, cc: g ? HYDRO : '', replyTo: HYDRO, consultaIds: itens.map(c => c.id),
    subject: `Passageiro fora de rota: ${lista.length} colaborador(es) em ônibus diferente da rota cadastrada (${hoje})${g ? '' : ' — encaminhar ao gestor'}`,
    html: moldura('Análise de passageiros fora de rota', `${lista.length} colaborador(es)${g && g.nome ? ' · ' + esc(g.nome) : ''} · ${hoje}`, aviso + faixa + cards),
  }});
}
return out;
