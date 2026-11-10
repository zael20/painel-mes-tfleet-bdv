/**
 * Robô de e-mail do QUADRO DE SOLICITAÇÕES (Supabase) — faz duas coisas:
 *
 * 1) ENVIO: a cada 1 minuto pega os e-mails escritos no quadro (botão "Enviar e-mail")
 *    e envia pelo SEU Gmail, com anexos e o link "Veja a gestão dessa demanda" no fim.
 *    Ficam na sua pasta Enviados e as respostas chegam na sua caixa.
 *
 *    Também avisa você quando um fornecedor repassa a demanda e pede acesso para alguém.
 *
 * 2) PRAZOS: todo dia às 8h (Brasília) pergunta ao Supabase quais cartões precisam de aviso:
 *   - prazo VENCIDO e ainda não entregue;
 *   - prazo vence HOJE ou AMANHÃ;
 *   - sem prazo e X dias sem contato (padrão 5; muda no quadro).
 * Manda um e-mail para a lista de e-mails do cartão e sempre uma cópia para você
 * (a conta Google que roda este script). Cada cartão recebe no máximo 1 aviso por dia.
 *
 * Instalar (uma vez):
 *  1. https://script.google.com → Novo projeto → apague o que tiver e cole este arquivo.
 *  2. Troque COLE_A_CHAVE_AQUI pela chave do robô que aparece no quadro em "Contatos e acessos" (lá embaixo).
 *  3. Salve (Ctrl+S), escolha a função instalar em cima e clique em Executar.
 *     O Google pede autorização (Gmail + acesso externo): Avançado → Acessar → Permitir.
 *  Se já tinha instalado a versão antiga: cole esta por cima e execute instalar de novo.
 */

const CHAVE = 'COLE_A_CHAVE_AQUI';
const SB_URL = 'https://orhuxmsrdnugpogvtnbg.supabase.co';
const SB_KEY = 'sb_publishable_Hu4Ns0jDTesWzDmVseAl_Q_ubCJa5wL';   // chave pública (a mesma das páginas)
const HORA_DO_AVISO = 8;

function rpc_(fn, body) {
  const r = UrlFetchApp.fetch(SB_URL + '/rest/v1/rpc/' + fn, {
    method: 'post', contentType: 'application/json', muteHttpExceptions: true,
    headers: { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY },
    payload: JSON.stringify(body)
  });
  if (r.getResponseCode() >= 300) throw new Error(fn + ' → ' + r.getResponseCode() + ': ' + r.getContentText());
  return JSON.parse(r.getContentText() || 'null');
}

function verificarPrazos() {
  const cartoes = rpc_('sol_avisos', { p_chave: CHAVE }) || [];
  const dono = Session.getEffectiveUser().getEmail();
  const fmt = s => s ? s.split('-').reverse().join('/') : '—';
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  cartoes.forEach(c => {
    let motivo;
    if (c.situacao === 'vencido') motivo = 'PRAZO VENCIDO há ' + (-c.dias_para_prazo) + ' dia(s)';
    else if (c.situacao === 'vence_hoje') motivo = 'Prazo vence HOJE';
    else if (c.situacao === 'vence_amanha') motivo = 'Prazo vence AMANHÃ';
    else motivo = c.dias_sem_contato + ' dias SEM RESPOSTA e sem prazo definido';

    const para = (c.emails || []).filter(e => e.includes('@'));
    if (dono && !para.includes(dono.toLowerCase())) para.push(dono);

    const linhas = [
      ['Fornecedor', c.fornecedor], ['Responsável', c.responsavel || 'não informado'],
      ['Status', c.status], ['Enviada em', fmt(c.enviado_em)], ['Começou em', fmt(c.inicio_em)],
      ['Prazo', fmt(c.prazo) + (c.prazo_original && c.prazo_original !== c.prazo ? ' (era ' + fmt(c.prazo_original) + ')' : '')],
      ['Último contato', fmt(c.ultimo_contato)]
    ];
    const cor = c.situacao === 'vencido' ? '#c62828' : c.situacao === 'sem_resposta' ? '#e65100' : '#b26a00';
    const html =
      '<div style="font-family:Arial,sans-serif;max-width:560px">' +
      '<div style="background:' + cor + ';color:#fff;padding:12px 16px;border-radius:8px 8px 0 0;font-weight:bold">' + esc(motivo) + '</div>' +
      '<div style="border:1px solid #ddd;border-top:0;padding:16px;border-radius:0 0 8px 8px">' +
      '<div style="font-size:17px;font-weight:bold;margin-bottom:10px">' + esc(c.assunto) + '</div>' +
      '<table style="border-collapse:collapse;font-size:14px">' +
      linhas.map(l => '<tr><td style="color:#666;padding:3px 12px 3px 0">' + l[0] + '</td><td>' + esc(l[1]) + '</td></tr>').join('') +
      '</table>' +
      (c.link ? '<p style="font-size:14px">Documento: <a href="' + esc(c.link) + '">' + esc(c.link) + '</a></p>' : '') +
      '<p><a href="' + esc(c.link_quadro) + '" style="display:inline-block;background:#1565c0;color:#fff;padding:10px 16px;border-radius:6px;text-decoration:none">Abrir no quadro e atualizar</a></p>' +
      '<p style="color:#888;font-size:12px">Aviso automático do quadro de solicitações.</p></div></div>';

    MailApp.sendEmail({
      to: para.join(','),
      subject: '[Solicitação ' + c.id + '] ' + motivo + ' – ' + c.fornecedor + ': ' + c.assunto,
      htmlBody: html,
      body: motivo + '\n\n' + c.assunto + '\n' + linhas.map(l => l[0] + ': ' + l[1]).join('\n') + '\n\nAbrir no quadro: ' + c.link_quadro
    });
    rpc_('sol_aviso_marcar', { p_chave: CHAVE, p_id: c.id, p_motivo: motivo, p_para: para.join(', ') });
  });
  console.log(cartoes.length + ' aviso(s) enviado(s).');
}

/** Avisa você quando um fornecedor repassa a demanda e pede acesso para alguém de fora. */
function avisarPedidos_() {
  const r = rpc_('sol_pedidos_avisar', { p_chave: CHAVE });
  if (!r || !r.pedidos || !r.pedidos.length) return;
  const dono = Session.getEffectiveUser().getEmail();
  if (!dono) return;
  const linhas = r.pedidos.map(p => '• ' + p.pedido_por + ' quer dar acesso a ' + p.nome + ' (' + p.email + ')' +
    (p.assunto ? '\n  Demanda: ' + p.assunto : '') + (p.mensagem ? '\n  Recado: ' + p.mensagem : '')).join('\n\n');
  MailApp.sendEmail(dono, '[Quadro] Pedido de acesso: ' + r.pedidos.map(p => p.nome).join(', '),
    linhas + '\n\nAprove ou recuse em: ' + r.link + '\n(Quadro → Contatos e acessos → Pedidos de acesso)');
}

/** Envia a fila de e-mails escritos no quadro (roda a cada minuto). */
function enviarFila() {
  try { avisarPedidos_(); } catch (err) { console.log('pedidos: ' + err); }
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  for (let n = 0; n < 5; n++) {                       // até 5 e-mails por rodada
    const e = rpc_('sol_emails_pendentes', { p_chave: CHAVE });
    if (!e) return;
    try {
      const rodapeTxt = '\n\n---\nVeja a gestão dessa demanda neste link: ' + e.link;
      const html = '<div style="font-family:Arial,sans-serif;font-size:14px;line-height:1.5">' +
        esc(e.corpo).replace(/\n/g, '<br>') +
        '<div style="margin-top:22px;padding-top:12px;border-top:1px solid #ddd">' +
        '<a href="' + esc(e.link) + '" style="display:inline-block;background:#16324f;color:#fff;padding:10px 16px;border-radius:6px;text-decoration:none">Veja a gestão dessa demanda</a>' +
        '<div style="color:#888;font-size:12px;margin-top:6px">Qualquer pessoa com o link vê o andamento. Para atualizar, entre com a sua senha.<br>' + esc(e.link) + '</div></div></div>';
      const opc = { htmlBody: html };
      if (e.cc && e.cc.length) opc.cc = e.cc.join(',');
      if (e.anexos && e.anexos.length) {
        opc.attachments = e.anexos.map(a => Utilities.newBlob(Utilities.base64Decode(a.base64), a.tipo || 'application/octet-stream', a.nome));
      }
      GmailApp.sendEmail(e.para.join(','), e.assunto, e.corpo + rodapeTxt, opc);
      rpc_('sol_email_marcar', { p_chave: CHAVE, p_id: e.id, p_ok: true, p_erro: null });
    } catch (err) {
      rpc_('sol_email_marcar', { p_chave: CHAVE, p_id: e.id, p_ok: false, p_erro: String(err && err.message || err) });
    }
  }
}

/** Execute UMA vez: cria os disparos (envio a cada 1 min + prazos às 8h) e já testa. */
function instalar() {
  ScriptApp.getProjectTriggers()
    .filter(t => ['verificarPrazos', 'enviarFila'].includes(t.getHandlerFunction()))
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('enviarFila').timeBased().everyMinutes(1).create();
  ScriptApp.newTrigger('verificarPrazos').timeBased().everyDays(1).atHour(HORA_DO_AVISO)
    .inTimezone('America/Sao_Paulo').create();
  enviarFila();
  verificarPrazos();
}
