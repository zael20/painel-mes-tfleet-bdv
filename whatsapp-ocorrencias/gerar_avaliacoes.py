# Gera fluxo-avaliacoes.json: a cada 30 min pega as avaliacoes de motorista com texto que ainda nao tem tema,
# pede ao Gemini para juntar as que dizem a mesma coisa (reaproveitando os temas que ja existem) e grava no Supabase.
# Uso: python3 gerar_avaliacoes.py [saida.json]   (placeholders __SUPABASE_URL__, __GEMINI_URL__)
# Sem avaliacao nova o fluxo para no 2o passo e nao gasta a cota do Gemini.
import json, sys

CRED_SUPA = {"httpHeaderAuth": {"id": "credSupabase0001", "name": "Supabase (chave secreta)"}}
CRED_GEM  = {"httpHeaderAuth": {"id": "credGeminiKey001", "name": "Gemini"}}

SYS = """Voce organiza as criticas dos motoristas de onibus sobre o atendimento de problemas no celular do onibus
(celular com o app da viagem, leitor RFID que conta passageiros, carregador/cabo, suporte do celular, chip/internet).
Cada avaliacao traz a nota (1 a 5), os motivos marcados e o texto do motorista.
Para cada avaliacao escolha UM tema que diga o mesmo problema de fundo:
- Use um tema EXISTENTE (tema_id) sempre que ele servir, mesmo com palavras diferentes.
  Ex.: "podia ter trocado o suporte", "o suporte continuou quebrado" e "o suporte esta quase quebrando" sao o MESMO tema.
- So crie tema novo (novo_titulo + nova_melhoria) quando nenhum existente servir.
  Avaliacoes deste lote que dizem a mesma coisa recebem EXATAMENTE o mesmo novo_titulo.
- novo_titulo: o problema, especifico e curto (ate 60 caracteres). Ex.: "Suporte do celular nao foi resolvido de vez".
  Nada generico como "Problemas" ou "Insatisfacao".
- nova_melhoria: o que a equipe deve fazer, comecando com verbo (ate 120 caracteres).
  Ex.: "Verificar o suporte com mais frequencia durante a vistoria".
- sem_tema = true quando o texto nao traz critica nem sugestao (ex.: "nada", "ok", "tudo certo").
Responda em portugues do Brasil."""

MONTAR = r"""// Monta o pedido ao Gemini. Sem avaliacao nova: nenhum item sai e o fluxo para aqui.
const r = $input.first().json || {};
const itens = r.itens || [];
if (!itens.length) return [];
const temas = (r.temas || []).map(t => `#${t.id} | ${t.titulo} | melhoria: ${t.melhoria || '-'} | ${t.qtd} avaliacoes`).join('\n') || '(nenhum ainda)';
const lista = itens.map(a => `id ${a.id} | nota ${a.nota} | ocorrencia: ${a.categoria} - ${a.problema || ''} | solucao dada: ${a.solucao || '-'}` +
  ` | motivos: ${(a.motivos || []).join('; ') || '-'} | texto: ${a.observacao}`).join('\n');
const SYS = __SYS__;
return [{ json: {
  ids: itens.map(a => a.id),
  pedido: {
    system_instruction: { parts: [{ text: SYS }] },
    contents: [{ role: 'user', parts: [{ text: `TEMAS QUE JA EXISTEM:\n${temas}\n\nAVALIACOES PARA AGRUPAR:\n${lista}` }] }],
    generationConfig: { temperature: 0.1, responseMimeType: 'application/json',
      responseSchema: { type: 'OBJECT', properties: { itens: { type: 'ARRAY', items: { type: 'OBJECT', properties: {
        id: { type: 'INTEGER' }, tema_id: { type: 'INTEGER', nullable: true }, novo_titulo: { type: 'STRING' },
        nova_melhoria: { type: 'STRING' }, sem_tema: { type: 'BOOLEAN' } }, required: ['id'] } } }, required: ['itens'] } },
  },
} }];
""".replace("__SYS__", json.dumps(SYS, ensure_ascii=False))

LER = r"""// Le a resposta do Gemini. Se falhar (cota, erro), nada e gravado e as avaliacoes voltam no proximo ciclo.
const ids = $('Montar pedido IA').first().json.ids;
const g = $input.first().json || {};
if (g.error) throw new Error('Gemini: ' + (g.error.message || JSON.stringify(g.error)));
const txt = (g.candidates?.[0]?.content?.parts || []).map(p => p.text || '').join('');
const r = JSON.parse(txt);
const itens = (r.itens || []).filter(i => ids.includes(i.id));
if (!itens.length) return [];
return [{ json: { p: { itens } } }];
"""

def http(name, pos, url, body, cred, timeout=30000, retry=False):
    n = {"parameters": {"method": "POST", "url": url, "authentication": "genericCredentialType",
                        "genericAuthType": "httpHeaderAuth", "sendBody": True, "specifyBody": "json",
                        "jsonBody": body, "options": {"timeout": timeout}},
         "name": name, "type": "n8n-nodes-base.httpRequest", "typeVersion": 4.2, "position": pos, "credentials": cred}
    if retry: n.update(retryOnFail=True, maxTries=2, waitBetweenTries=5000)
    return n

def code(name, js, pos):
    return {"parameters": {"jsCode": js}, "name": name, "type": "n8n-nodes-base.code", "typeVersion": 2, "position": pos}

nodes = [
  {"parameters": {"rule": {"interval": [{"field": "minutes", "minutesInterval": 30}]}}, "name": "A cada 30 minutos",
   "type": "n8n-nodes-base.scheduleTrigger", "typeVersion": 1.2, "position": [0, 300]},
  http("Avaliacoes sem tema", [220, 300], "__SUPABASE_URL__/rest/v1/rpc/avaliacoes_para_agrupar", '={"p_limite": 25}', CRED_SUPA),
  code("Montar pedido IA", MONTAR, [440, 300]),
  http("Gemini", [660, 300], "__GEMINI_URL__", "={{ JSON.stringify($json.pedido) }}", CRED_GEM, timeout=120000, retry=True),
  code("Ler resposta IA", LER, [880, 300]),
  http("Gravar temas", [1100, 300], "__SUPABASE_URL__/rest/v1/rpc/avaliacoes_aplicar_temas", "={{ JSON.stringify($json) }}", CRED_SUPA),
]
def c(t): return {"main": [[{"node": t, "type": "main", "index": 0}]]}
connections = {"A cada 30 minutos": c("Avaliacoes sem tema"), "Avaliacoes sem tema": c("Montar pedido IA"),
               "Montar pedido IA": c("Gemini"), "Gemini": c("Ler resposta IA"), "Ler resposta IA": c("Gravar temas")}
wf = {"id": "avaliacoesTemas1", "name": "Agrupar avaliacoes dos motoristas", "nodes": nodes, "connections": connections,
      "active": False, "settings": {"executionOrder": "v1", "saveDataSuccessExecution": "none", "saveDataErrorExecution": "all"},
      "pinData": {}}
json.dump(wf, open(sys.argv[1] if len(sys.argv) > 1 else "fluxo-avaliacoes.json", "w"), ensure_ascii=False, indent=1)
