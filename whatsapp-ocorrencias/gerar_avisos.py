# Gera fluxo-avisos.json: a cada 2 min pega no Supabase as ocorrencias resolvidas que ainda nao foram avisadas
# e responde no grupo EM CIMA da mensagem do relato (Evolution API /message/sendText com "quoted").
# Uso: python3 gerar_avisos.py [saida.json]   (placeholders __SUPABASE_URL__, __EVOLUTION_URL__, __INSTANCIA__)
# Quem liga/desliga e o Supabase (tabela whatsapp_avisos); o fluxo pode ficar sempre ativo.
# linkPreview false: o link da avaliacao vai como texto simples, sem o cartao grande de previa.
# 2a corrente (06/11): relato sem numero do carro -> pergunta o numero EM CIMA da mensagem do motorista
# (perguntas_carro_pendentes / pergunta_marcar; liga/desliga em whatsapp_avisos.perguntar_carro).
import json, sys

CRED_EVO  = {"httpHeaderAuth": {"id": "credEvolution001", "name": "Evolution API"}}
CRED_SUPA = {"httpHeaderAuth": {"id": "credSupabase0001", "name": "Supabase (chave secreta)"}}

SEPARAR = r"""// Um item por aviso. Lista vazia (desligado, fora do expediente, limite por hora) = fluxo para aqui.
const r = $input.first().json || {};
return (r.avisos || []).map(a => ({ json: a }));
"""

SEPARAR_P = r"""// Um item por pergunta "qual o numero do carro?". Lista vazia (desligado, limite por hora) = para aqui.
const r = $input.first().json || {};
return (r.perguntas || []).map(a => ({ json: a }));
"""

RESULTADO_P = r"""// Guarda o id da pergunta enviada: a resposta "Carro 84" citando ela vai para a ocorrencia certa.
const a = $('Separar perguntas').item.json;
const r = $json || {};
const ok = !!(r.key && r.key.id);
const erro = ok ? null : String(r.error?.message || r.message || r.error || JSON.stringify(r)).slice(0, 500);
return { json: { p_id: a.id, p_ok: ok, p_erro: erro, p_msg_id: ok ? r.key.id : null } };
"""

RESULTADO = r"""// Resposta da Evolution: deu certo se voltou a chave da mensagem enviada.
const a = $('Separar avisos').item.json;
const r = $json || {};
const ok = !!(r.key && r.key.id);
const erro = ok ? null : String(r.error?.message || r.message || r.error || JSON.stringify(r)).slice(0, 500);
return { json: { p_id: a.id, p_ok: ok, p_erro: erro } };
"""

def http(name, pos, url, body, cred, on_error=False):
    n = {"parameters": {"method": "POST", "url": url, "authentication": "genericCredentialType",
                        "genericAuthType": "httpHeaderAuth", "sendBody": True, "specifyBody": "json",
                        "jsonBody": body, "options": {"timeout": 30000}},
         "name": name, "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2, "position": pos, "credentials": cred}
    if on_error: n["onError"] = "continueRegularOutput"
    return n

def code(name, js, pos, each=False):
    p = {"jsCode": js}
    if each: p["mode"] = "runOnceForEachItem"
    return {"parameters": p, "name": name, "type": "n8n-nodes-base.code", "typeVersion": 2, "position": pos}

ENVIO = ("={{ JSON.stringify({ number: $json.grupo_jid, text: $json.texto, delay: 1500, linkPreview: false, "
         "quoted: { key: { id: $json.quoted_id, remoteJid: $json.grupo_jid, fromMe: false, participant: $json.autor_jid }, "
         "message: { conversation: $json.quoted_texto } } }) }}")

nodes = [
  {"parameters": {"rule": {"interval": [{"field": "minutes", "minutesInterval": 2}]}}, "name": "A cada 2 minutos",
   "type": "n8n-nodes-base.scheduleTrigger", "typeVersion": 1.2, "position": [0, 300]},
  http("Avisos pendentes", [220, 300], "__SUPABASE_URL__/rest/v1/rpc/avisos_pendentes", '={"p_limite": 1}', CRED_SUPA),
  code("Separar avisos", SEPARAR, [440, 300]),
  http("Responder no grupo", [660, 300], "__EVOLUTION_URL__/message/sendText/__INSTANCIA__", ENVIO, CRED_EVO, on_error=True),
  code("Resultado", RESULTADO, [880, 300], each=True),
  http("Marcar avisada", [1100, 300], "__SUPABASE_URL__/rest/v1/rpc/aviso_marcar", "={{ JSON.stringify($json) }}", CRED_SUPA),
  http("Perguntas pendentes", [220, 520], "__SUPABASE_URL__/rest/v1/rpc/perguntas_carro_pendentes", '={"p_limite": 1}', CRED_SUPA),
  code("Separar perguntas", SEPARAR_P, [440, 520]),
  http("Perguntar no grupo", [660, 520], "__EVOLUTION_URL__/message/sendText/__INSTANCIA__", ENVIO, CRED_EVO, on_error=True),
  code("Resultado pergunta", RESULTADO_P, [880, 520], each=True),
  http("Marcar perguntada", [1100, 520], "__SUPABASE_URL__/rest/v1/rpc/pergunta_marcar", "={{ JSON.stringify($json) }}", CRED_SUPA),
]
def c(t): return {"main": [[{"node": t, "type": "main", "index": 0}]]}
connections = {"A cada 2 minutos": {"main": [[{"node": "Avisos pendentes", "type": "main", "index": 0},
                                              {"node": "Perguntas pendentes", "type": "main", "index": 0}]]},
               "Avisos pendentes": c("Separar avisos"),
               "Separar avisos": c("Responder no grupo"), "Responder no grupo": c("Resultado"), "Resultado": c("Marcar avisada"),
               "Perguntas pendentes": c("Separar perguntas"), "Separar perguntas": c("Perguntar no grupo"),
               "Perguntar no grupo": c("Resultado pergunta"), "Resultado pergunta": c("Marcar perguntada")}
wf = {"id": "ocorrAvisos00001", "name": "Avisos de resolucao no WhatsApp", "nodes": nodes, "connections": connections,
      "active": False, "settings": {"executionOrder": "v1", "saveDataSuccessExecution": "none", "saveDataErrorExecution": "all"},
      "pinData": {}}
json.dump(wf, open(sys.argv[1] if len(sys.argv) > 1 else "fluxo-avisos.json", "w"), ensure_ascii=False, indent=1)
