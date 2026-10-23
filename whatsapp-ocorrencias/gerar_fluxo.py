#!/usr/bin/env python3
"""Gera o fluxo do n8n (fluxo-ocorrencias.json). Placeholders __GRUPOS__, __SUPABASE_URL__, __GEMINI_URL__,
__EVOLUTION_URL__ sao trocados pelo configurar.sh na VM."""
import json, sys

CRED_EVO  = {"httpHeaderAuth": {"id": "credEvolution001", "name": "Evolution API"}}
CRED_SUPA = {"httpHeaderAuth": {"id": "credSupabase0001", "name": "Supabase (chave secreta)"}}
CRED_GEM  = {"httpHeaderAuth": {"id": "credGeminiKey001", "name": "Gemini"}}

PREPARAR = r"""// Le a mensagem que a Evolution API mandou e decide o que fazer com ela.
// ====== CONFIGURACAO (preenchida pelo configurar.sh) ======
const CFG = {
  grupos: '__GRUPOS__'.split(',').map(s => s.trim()).filter(Boolean),   // ids dos grupos lidos
  supabase: '__SUPABASE_URL__',
  evolution: '__EVOLUTION_URL__',
  gemini: '__GEMINI_URL__',
};
// Mensagens curtas sem informacao nao gastam a cota do Gemini (ficam registradas como "ignorar").
const TRIVIAL = /^(ok+|okay|blz|beleza|bom dia|boa tarde|boa noite|obrigad[oa]s?|obg|vlw|valeu|show|certo|sim|n[aã]o|t[aá]|ta bom|entendi|kk+|rs+|haha+|[\u{1F300}-\u{1FAFF}☀-➿\s]+)[\s!.,]*$/iu;

const out = [];
for (const item of $input.all()) {
  const b = item.json.body || item.json;
  const evento = String(b.event || '').toLowerCase().replace('_', '.');
  if (evento !== 'messages.upsert') continue;
  const lista = Array.isArray(b.data) ? b.data : [b.data];
  for (const d of lista) {
    if (!d || !d.key) continue;
    const jid = d.key.remoteJid || '';
    if (!jid.endsWith('@g.us')) continue;                         // so grupos
    if (CFG.grupos.length && !CFG.grupos.includes(jid)) continue; // so o(s) grupo(s) escolhido(s)
    if (d.key.fromMe) continue;
    const raw = d.message || {};
    const m = raw.ephemeralMessage?.message || raw.viewOnceMessageV2?.message || raw.viewOnceMessage?.message || raw;
    let tipo = 'outro', texto = '', mime = '', tamanho = 0, tem_midia = false;
    if (m.conversation) { tipo = 'texto'; texto = m.conversation; }
    else if (m.extendedTextMessage) { tipo = 'texto'; texto = m.extendedTextMessage.text || ''; }
    else if (m.audioMessage) { tipo = 'audio'; mime = m.audioMessage.mimetype; tamanho = +m.audioMessage.fileLength || 0; tem_midia = true; }
    else if (m.videoMessage) { tipo = 'video'; texto = m.videoMessage.caption || ''; mime = m.videoMessage.mimetype; tamanho = +m.videoMessage.fileLength || 0; tem_midia = true; }
    else if (m.imageMessage) { tipo = 'imagem'; texto = m.imageMessage.caption || ''; mime = m.imageMessage.mimetype; tamanho = +m.imageMessage.fileLength || 0; tem_midia = true; }
    else if (m.documentMessage || m.documentWithCaptionMessage) {
      const doc = m.documentMessage || m.documentWithCaptionMessage?.message?.documentMessage || {};
      tipo = 'documento'; texto = doc.caption || doc.fileName || '';
    }
    else continue; // reacao, figurinha, enquete, mensagem apagada, etc.

    if (tem_midia && tamanho > 15 * 1024 * 1024) { // grande demais para o Gemini gratis e para o Storage
      tem_midia = false;
      texto = (texto ? texto + ' ' : '') + `[${tipo} de ${(tamanho / 1048576).toFixed(0)} MB nao analisado]`;
    }
    const ts = d.messageTimestamp ? new Date(Number(d.messageTimestamp) * 1000) : new Date();
    out.push({ json: {
      cfg: CFG,
      instancia: b.instance || '',
      key: d.key,
      precisa_ia: tem_midia || !TRIVIAL.test(texto.trim()),
      tem_midia,
      msg: {
        msg_id: d.key.id,
        ts: ts.toISOString(),
        grupo_jid: jid,
        autor_nome: d.pushName || '',
        autor_jid: d.key.participantPn || d.key.participantAlt || d.key.participant || d.participant || '',
        tipo,
        texto: texto.slice(0, 4000),
        midia_tipo: (mime || '').split(';')[0],
      },
    }});
  }
}
return out;
"""

ANEXAR = r"""// Transforma a midia baixada em arquivo (para guardar no Supabase) e guarda o base64 para o Gemini.
const prep = $('Preparar mensagem').item.json;
const b64 = $json.base64 || '';
const mime = String($json.mimetype || prep.msg.midia_tipo || 'application/octet-stream').split(';')[0];
const bytes = Math.floor(b64.length * 3 / 4);
const ext = { 'audio/ogg': 'ogg', 'audio/mpeg': 'mp3', 'audio/mp4': 'm4a', 'audio/aac': 'aac', 'video/mp4': 'mp4',
  'video/3gpp': '3gp', 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' }[mime] || 'bin';
const codigo = Math.random().toString(36).slice(2, 12);
const caminho = `${prep.msg.ts.slice(0, 7)}/${prep.msg.msg_id}-${codigo}.${ext}`;
const item = { json: { midia: { ok: !!b64, mime, bytes, caminho, b64 } } };
if (b64) item.binary = { data: { data: b64, mimeType: mime, fileName: caminho.split('/').pop() } };
return item;
"""

SYS = ("Voce analisa mensagens de um grupo de WhatsApp onde motoristas e a equipe relatam problemas nos CELULARES "
"instalados nos onibus da frota. Nesses celulares rodam o aplicativo BDV (abrir/encerrar viagem) e um leitor RFID por "
"Bluetooth que conta passageiros; o celular fica no suporte, ligado no carregador, com chip de internet.\n\n"
"Para a MENSAGEM NOVA, devolva uma lista 'acoes' (normalmente 1 item; varios so se citar varios onibus ou problemas):\n"
"- acao 'nova': relata um problema que NAO esta na lista de ocorrencias abertas.\n"
"- acao 'atualiza': repete ou complementa uma ocorrencia aberta (mesmo onibus e mesmo problema). Informe ocorrencia_id.\n"
"- acao 'resolve': alguem diz que um problema foi resolvido/consertado/trocado. Informe ocorrencia_id e a solucao.\n"
"- acao 'ignorar': conversa sem problema tecnico de celular (cumprimentos, escalas, perguntas gerais, avisos).\n\n"
"tag = numero do onibus, so digitos ('carro 65', 'o 065', 'onibus 7' -> '65', '65', '7'). Se a mensagem nova nao citar o "
"onibus, use o que o MESMO autor citou nas mensagens anteriores dos ultimos minutos; se ainda assim nao souber, deixe vazio.\n"
"categoria: carregamento (nao carrega, carrega devagar, cabo, carregador, tomada, bateria descarregando) | "
"abrir_viagem (app BDV nao abre/inicia/encerra viagem, login, app travado) | contagem_passageiros (nao conta passageiro, "
"leitor RFID, cartao nao le, Bluetooth do leitor) | internet_chip (sem internet, sem sinal, chip, dados) | celular_defeito "
"(tela quebrada, travando, desligando, nao liga, sumiu) | suporte (suporte solto ou quebrado) | som_musica (som, musica, "
"volume, radio) | outro.\n"
"urgencia: alta = onibus rodando sem abrir viagem, sem contar passageiros ou com celular inoperante; media = funciona com "
"falha; baixa = informativo.\n"
"problema = frase curta e objetiva em portugues (ate 120 caracteres), sem nome de pessoa.\n"
"confianca = 0 a 1, o quanto voce tem certeza da acao e do onibus.\n"
"transcricao = se houver audio, video ou imagem, transcreva ou descreva o conteudo em ate 500 caracteres; senao vazio.\n"
"Responda somente o JSON pedido.")

MONTAR = r"""// Junta a mensagem nova, o contexto do grupo e a midia num pedido para o Gemini.
const prep = $('Preparar mensagem').item.json;
let midia = null, link = '';
if ($('Anexar midia').isExecuted) { try { midia = $('Anexar midia').item.json.midia; } catch (e) {} }
if ($('Link da midia').isExecuted) {
  try { const s = $('Link da midia').item.json.signedURL; if (s) link = prep.cfg.supabase + '/storage/v1' + s; } catch (e) {}
}
const ctx = $('Contexto do grupo').item.json || {};
const hora = iso => new Date(iso).toLocaleString('pt-BR', { timeZone: 'America/Belem', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
const anteriores = (ctx.mensagens || []).filter(x => x.texto).map(x => `[${hora(x.ts)}] ${x.autor_nome || '?'}: ${x.texto}${x.ocorrencia_id ? ` (ocorrencia ${x.ocorrencia_id})` : ''}`).join('\n') || '(nenhuma)';
const abertas = (ctx.abertas || []).map(o => `#${o.id} | onibus ${o.tag || '?'} | ${o.categoria} | ${o.problema} | ${o.status}`).join('\n') || '(nenhuma)';
const nova = `[${hora(prep.msg.ts)}] ${prep.msg.autor_nome || '?'} (${prep.msg.tipo}): ${prep.msg.texto || '(sem texto)'}`;

const parts = [{ text: `OCORRENCIAS ABERTAS:\n${abertas}\n\nMENSAGENS ANTERIORES DO GRUPO (ultimas 2 horas):\n${anteriores}\n\nMENSAGEM NOVA:\n${nova}${midia && midia.b64 ? '\n(a midia desta mensagem vai anexada)' : ''}` }];
if (midia && midia.b64 && midia.bytes <= 18 * 1024 * 1024) parts.push({ inline_data: { mime_type: midia.mime, data: midia.b64 } });

const SYS = __SYS__;
const ACAO = { type: 'OBJECT', properties: {
  acao: { type: 'STRING', enum: ['nova', 'atualiza', 'resolve', 'ignorar'] },
  tag: { type: 'STRING' },
  categoria: { type: 'STRING', enum: ['carregamento', 'abrir_viagem', 'contagem_passageiros', 'internet_chip', 'celular_defeito', 'suporte', 'som_musica', 'outro'] },
  problema: { type: 'STRING' },
  urgencia: { type: 'STRING', enum: ['baixa', 'media', 'alta'] },
  ocorrencia_id: { type: 'INTEGER', nullable: true },
  solucao: { type: 'STRING' },
  confianca: { type: 'NUMBER' } }, required: ['acao', 'confianca'] };

return { json: {
  gemini_url: prep.cfg.gemini,
  supabase: prep.cfg.supabase,
  modelo: (prep.cfg.gemini.match(/models\/([^:]+)/) || [])[1] || '',
  registro: { ...prep.msg, midia_path: link || null },
  pedido: {
    system_instruction: { parts: [{ text: SYS }] },
    contents: [{ role: 'user', parts }],
    generationConfig: { temperature: 0.1, responseMimeType: 'application/json',
      responseSchema: { type: 'OBJECT', properties: { transcricao: { type: 'STRING' }, acoes: { type: 'ARRAY', items: ACAO } }, required: ['acoes'] } },
  },
}};
""".replace("__SYS__", json.dumps(SYS, ensure_ascii=False))

LER = r"""// Le a resposta do Gemini e monta 1 registro por acao. Se a IA falhar (cota, erro), a mensagem e guardada como "erro".
const saida = [];
const pedidos = $('Montar pedido IA').all();
$input.all().forEach((it, i) => {
  const base = pedidos[i].json;
  let r = null, erro = '';
  try {
    if (it.json.error) throw new Error(typeof it.json.error === 'string' ? it.json.error : (it.json.error.message || JSON.stringify(it.json.error)));
    const txt = (it.json.candidates?.[0]?.content?.parts || []).map(p => p.text || '').join('');
    r = JSON.parse(txt);
  } catch (e) { erro = String(e.message || e).slice(0, 300); }
  const acoes = r && Array.isArray(r.acoes) && r.acoes.length ? r.acoes : [{ acao: erro ? 'erro' : 'ignorar', confianca: 0 }];
  acoes.slice(0, 5).forEach((a, j) => {
    saida.push({ json: { supabase: base.supabase, p: {
      ...base.registro,
      msg_id: base.registro.msg_id + (j ? '#' + j : ''),
      transcricao: (r && r.transcricao) || '',
      ia: { ...a, modelo: base.modelo, ...(erro ? { erro } : {}) },
    } } });
  });
});
return saida;
"""

SEM_IA = r"""// Mensagem curta sem informacao (ok, bom dia...): registra sem gastar a IA.
return { json: { supabase: $json.cfg.supabase, p: { ...$json.msg, midia_path: null, ia: { acao: 'ignorar', motivo: 'mensagem curta' } } } };
"""

def code(name, js, pos, each=False):
    p = {"jsCode": js}
    if each: p["mode"] = "runOnceForEachItem"
    return {"parameters": p, "name": name, "type": "n8n-nodes-base.code", "typeVersion": 2, "position": pos}

def http(name, pos, url, body=None, cred=None, binary=False, headers=None, timeout=60000, on_error=True, retry=False):
    p = {"method": "POST", "url": url, "options": {"timeout": timeout}}
    if cred:
        p["authentication"] = "genericCredentialType"; p["genericAuthType"] = "httpHeaderAuth"
    if headers:
        p["sendHeaders"] = True
        p["headerParameters"] = {"parameters": [{"name": k, "value": v} for k, v in headers]}
    p["sendBody"] = True
    if binary:
        p["contentType"] = "binaryData"; p["inputDataFieldName"] = "data"
    else:
        p["specifyBody"] = "json"; p["jsonBody"] = body
    n = {"parameters": p, "name": name, "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2, "position": pos}
    if cred: n["credentials"] = cred
    if on_error: n["onError"] = "continueRegularOutput"
    if retry: n.update({"retryOnFail": True, "maxTries": 3, "waitBetweenTries": 5000})
    return n

def iff(name, pos, expr):
    return {"parameters": {"conditions": {"options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose", "version": 2},
              "conditions": [{"id": name.replace(" ", "")[:12], "leftValue": expr, "rightValue": "",
                              "operator": {"type": "boolean", "operation": "true", "singleValue": True}}],
              "combinator": "and"}, "options": {}},
            "name": name, "type": "n8n-nodes-base.if", "typeVersion": 2.2, "position": pos}

P = "$('Preparar mensagem').item.json"
nodes = [
  {"parameters": {"httpMethod": "POST", "path": "whatsapp-ocorrencias", "options": {}}, "name": "Mensagem do WhatsApp",
   "type": "n8n-nodes-base.webhook", "typeVersion": 2, "position": [0, 300], "webhookId": "7d1f0c52-0d55-4f4b-9a1e-5a0c1c0d0a01"},
  code("Preparar mensagem", PREPARAR, [220, 300]),
  iff("Precisa da IA?", [440, 300], "={{ $json.precisa_ia }}"),
  code("Sem IA", SEM_IA, [660, 460], each=True),
  http("Contexto do grupo", [660, 200], "={{ $json.cfg.supabase }}/rest/v1/rpc/contexto_ia",
       body="={{ JSON.stringify({ p_grupo: $json.msg.grupo_jid, p_msg_id: $json.msg.msg_id }) }}", cred=CRED_SUPA, on_error=False, retry=True),
  iff("Mensagem nova?", [880, 200], "={{ !$json.duplicada }}"),
  iff("Tem midia?", [1100, 200], "={{ " + P + ".tem_midia }}"),
  http("Baixar midia", [1320, 80], "={{ " + P + ".cfg.evolution }}/chat/getBase64FromMediaMessage/{{ " + P + ".instancia }}",
       body="={{ JSON.stringify({ message: { key: " + P + ".key }, convertToMp4: false }) }}", cred=CRED_EVO, timeout=120000),
  code("Anexar midia", ANEXAR, [1540, 80], each=True),
  http("Guardar midia", [1760, 80], "={{ " + P + ".cfg.supabase }}/storage/v1/object/whatsapp-midia/{{ $json.midia.caminho }}",
       cred=CRED_SUPA, binary=True, headers=[("x-upsert", "true")], timeout=120000),
  http("Link da midia", [1980, 80], "={{ " + P + ".cfg.supabase }}/storage/v1/object/sign/whatsapp-midia/{{ $('Anexar midia').item.json.midia.caminho }}",
       body='={"expiresIn": 31536000}', cred=CRED_SUPA),
  code("Montar pedido IA", MONTAR, [2200, 300], each=True),
  dict(http("Gemini", [2420, 300], "={{ $json.gemini_url }}", body="={{ JSON.stringify($json.pedido) }}", cred=CRED_GEM, timeout=180000, retry=True), maxTries=2),
  code("Ler resposta IA", LER, [2640, 300]),
  http("Registrar no Supabase", [2860, 420], "={{ $json.supabase }}/rest/v1/rpc/registrar_mensagem",
       body="={{ JSON.stringify({ p: $json.p }) }}", cred=CRED_SUPA, on_error=False, retry=True),
]
def c(*targets): return {"main": [[{"node": t, "type": "main", "index": 0} for t in br] for br in targets]}
connections = {
  "Mensagem do WhatsApp": c(["Preparar mensagem"]),
  "Preparar mensagem": c(["Precisa da IA?"]),
  "Precisa da IA?": c(["Contexto do grupo"], ["Sem IA"]),
  "Contexto do grupo": c(["Mensagem nova?"]),
  "Mensagem nova?": c(["Tem midia?"], []),
  "Tem midia?": c(["Baixar midia"], ["Montar pedido IA"]),
  "Baixar midia": c(["Anexar midia"]),
  "Anexar midia": c(["Guardar midia"]),
  "Guardar midia": c(["Link da midia"]),
  "Link da midia": c(["Montar pedido IA"]),
  "Montar pedido IA": c(["Gemini"]),
  "Gemini": c(["Ler resposta IA"]),
  "Ler resposta IA": c(["Registrar no Supabase"]),
  "Sem IA": c(["Registrar no Supabase"]),
}
wf = {"id": "ocorrWhatsapp001", "name": "Ocorrencias do WhatsApp", "nodes": nodes, "connections": connections,
      "active": False, "settings": {"executionOrder": "v1", "saveDataSuccessExecution": "all", "saveDataErrorExecution": "all"},
      "pinData": {}}
json.dump(wf, open(sys.argv[1] if len(sys.argv) > 1 else "fluxo-ocorrencias.json", "w"), ensure_ascii=False, indent=1)
