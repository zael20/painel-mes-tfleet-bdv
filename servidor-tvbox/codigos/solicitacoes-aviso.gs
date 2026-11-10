/**
 * Aviso de prazos do QUADRO DE SOLICITAÇÕES (Supabase)
 *
 * Todo dia às 8h (Brasília) pergunta ao Supabase quais cartões precisam de aviso:
 *   - prazo VENCIDO e ainda não entregue;
 *   - prazo vence HOJE ou AMANHÃ;
 *   - sem prazo e X dias sem contato (padrão 5; muda no quadro).
 * Manda um e-mail para a lista de e-mails do cartão e sempre uma cópia para você
 * (a conta Google que roda este script). Cada cartão recebe no máximo 1 aviso por dia.
 *
 * Instalar (uma vez):
 *  1. https://script.google.com → Novo projeto → apague o que tiver e cole este arquivo.
 *  2. Troque COLE_A_CHAVE_AQUI pela chave que aparece no quadro em  Acessos → Aviso por e-mail.
 *  3. Salve (Ctrl+S), escolha a função instalarAvisoDiario em cima e clique em Executar.
 *     O Google pede autorização (e-mail + acesso externo): Permitir.
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

/** Execute UMA vez: cria o disparo diário (apaga um antigo, se existir) e já testa. */
function instalarAvisoDiario() {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'verificarPrazos')
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('verificarPrazos').timeBased().everyDays(1).atHour(HORA_DO_AVISO)
    .inTimezone('America/Sao_Paulo').create();
  verificarPrazos();
}
