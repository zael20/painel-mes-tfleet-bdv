#!/usr/bin/env bash
# Liga o fluxo de ocorrencias: guarda as chaves, escolhe o grupo e ativa o n8n.
# Uso na TV Box, depois do instalar.sh e de conectar o numero na Evolution:  sudo servidor whatsapp
# Pode rodar de novo (para trocar chave, grupo ou atualizar o fluxo). Enter mantem o valor atual.
set -euo pipefail

DIR="${DIR:-/opt/servidor}"
RAW="${RAW:-https://raw.githubusercontent.com/zael20/painel-mes-tfleet-bdv/main/whatsapp-ocorrencias}"
SUPABASE_PADRAO="https://orhuxmsrdnugpogvtnbg.supabase.co"
WF_ID="ocorrWhatsapp001"

ok()   { echo -e "\e[32m[OK]\e[0m $*"; }
info() { echo -e "\e[36m[..]\e[0m $*"; }
aviso(){ echo -e "\e[33m[!]\e[0m $*"; }
erro() { echo -e "\e[31m[ERRO]\e[0m $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || erro "Rode com sudo:  sudo servidor whatsapp"
[ -f "$DIR/.env" ] || erro "Nao achei $DIR. Rode primeiro o instalar.sh"
cd "$DIR"
set -a; source .env; source segredos.env; [ -f config.env ] && source config.env; set +a
command -v python3 >/dev/null || apt-get install -y -qq python3 >/dev/null
EVO="${EVO_URL:-https://${EVO_HOST:-}}"
DC="docker compose -f $DIR/docker-compose.yml --project-directory $DIR"

# pergunta com valor padrao; segredos aparecem so com o final
pergunta() { # $1 texto  $2 valor atual  $3 secreto(1/0)
  local atual="$2" mostra="$2"
  [ "${3:-0}" = 1 ] && [ -n "$atual" ] && mostra="...${atual: -6}"
  local r s=""; [ "${3:-0}" = 1 ] && s="-s"   # segredo: nao aparece na tela ao colar
  read -r $s -p "$1${mostra:+ [$mostra]}: " r </dev/tty; [ -n "$s" ] && echo >/dev/tty
  echo "${r:-$atual}" | tr -d '[:space:]'
}
json() { python3 -c "import sys,json; d=json.load(sys.stdin); $1"; }

echo; echo "=== 1/4 Supabase ==="
SUPABASE_URL=$(pergunta "URL do projeto Supabase" "${SUPABASE_URL:-$SUPABASE_PADRAO}")
SUPABASE_URL=${SUPABASE_URL%/}
SUPABASE_KEY=$(pergunta "Chave SECRETA do Supabase (sb_secret_... ou service_role)" "${SUPABASE_KEY:-}" 1)
[ -n "$SUPABASE_KEY" ] || erro "Sem a chave secreta nao da para gravar as ocorrencias."
code=$(curl -s -o /tmp/r.json -w '%{http_code}' -X POST "$SUPABASE_URL/rest/v1/rpc/contexto_ia" \
  -H "apikey: $SUPABASE_KEY" -H "Content-Type: application/json" -d '{"p_grupo":"teste"}' || true)
case "$code" in
  200) ok "Supabase conectado e ocorrencias.sql ja rodado" ;;
  401|403) erro "Chave do Supabase recusada ($code). Confira se copiou a chave SECRETA (nao a publishable)." ;;
  404) erro "Funcao nao encontrada: rode o arquivo ocorrencias.sql no SQL Editor do Supabase e tente de novo." ;;
  *) erro "Supabase respondeu $code: $(head -c 300 /tmp/r.json)" ;;
esac

echo; echo "=== 2/4 Gemini ==="
GEMINI_KEY=$(pergunta "Chave da API do Gemini (AI Studio)" "${GEMINI_KEY:-}" 1)
[ -n "$GEMINI_KEY" ] || erro "Sem a chave do Gemini a IA nao funciona."
if [ -z "${GEMINI_MODEL:-}" ]; then
  GEMINI_MODEL=$(curl -s "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200" -H "x-goog-api-key: $GEMINI_KEY" | json "
import re
ms=[m['name'].split('/')[-1] for m in d.get('models',[]) if 'generateContent' in m.get('supportedGenerationMethods',[])]
lite=[m for m in ms if 'flash-lite' in m and not re.search(r'tts|image|live|audio', m)]
ver=lambda m: [float(x) for x in re.findall(r'\d+(?:\.\d+)?', m)[:1]] or [0]
est=[m for m in lite if not re.search(r'preview|exp|latest', m)] or lite
print(sorted(est, key=lambda m: (ver(m), -len(m)))[-1] if est else '')" 2>/dev/null || true)
fi
[ -n "$GEMINI_MODEL" ] || erro "Nao consegui listar os modelos do Gemini. A chave esta certa?"
GEMINI_MODEL=$(pergunta "Modelo do Gemini" "$GEMINI_MODEL")
code=$(curl -s -o /tmp/r.json -w '%{http_code}' -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/$GEMINI_MODEL:generateContent" \
  -H "x-goog-api-key: $GEMINI_KEY" -H "Content-Type: application/json" \
  -d '{"contents":[{"parts":[{"text":"Responda apenas: ok"}]}]}' || true)
case "$code" in
  200) ok "Gemini respondeu ($GEMINI_MODEL)" ;;
  429) aviso "Gemini sem cota agora (429). O fluxo fica pronto e volta a funcionar quando a cota renovar." ;;
  *) erro "Gemini respondeu $code: $(head -c 300 /tmp/r.json)" ;;
esac

echo; echo "=== 3/4 WhatsApp (Evolution) ==="
curl -s "$EVO/instance/fetchInstances" -H "apikey: $EVO_API_KEY" > /tmp/inst.json || erro "Evolution nao respondeu em $EVO"
python3 - <<'PY' || erro "Nenhum numero conectado. Conecte pelo QR code em http://<ip-da-box>:8080/manager e rode de novo."
import json
d = json.load(open('/tmp/inst.json'))
d = d if isinstance(d, list) else d.get('response', d.get('data', []))
lig = [i for i in d if (i.get('connectionStatus') or i.get('instance', {}).get('status')) == 'open']
for i in d:
    print(f"  - {i.get('name') or i.get('instance', {}).get('instanceName')}: {i.get('connectionStatus') or i.get('instance', {}).get('status')}")
open('/tmp/inst.txt', 'w').write('\n'.join(i.get('name') or i.get('instance', {}).get('instanceName') for i in lig))
raise SystemExit(0 if lig else 1)
PY
INSTANCIA=$(head -1 /tmp/inst.txt)
if [ "$(grep -c . /tmp/inst.txt)" -gt 1 ]; then INSTANCIA=$(pergunta "Qual instancia usar" "${INSTANCIA}"); fi
ok "Numero conectado: instancia '$INSTANCIA'"
# garante que a instancia NAO ignora grupos e nao marca mensagens como lidas
curl -s -o /dev/null -X POST "$EVO/settings/set/$INSTANCIA" -H "apikey: $EVO_API_KEY" -H "Content-Type: application/json" \
  -d '{"rejectCall":false,"msgCall":"","groupsIgnore":false,"alwaysOnline":false,"readMessages":false,"readStatus":false,"syncFullHistory":false}' || true

info "Buscando os grupos em que o numero esta (pode levar ate 1 minuto)..."
curl -s --max-time 90 "$EVO/group/fetchAllGroups/$INSTANCIA?getParticipants=false" -H "apikey: $EVO_API_KEY" > /tmp/grupos.json
python3 - <<'PY' || erro "O numero nao esta em nenhum grupo. Adicione o numero no grupo e rode de novo."
import json
d = json.load(open('/tmp/grupos.json'))
d = d if isinstance(d, list) else d.get('response', [])
d = sorted(d, key=lambda g: (g.get('subject') or '').lower())
for n, g in enumerate(d, 1):
    print(f"  {n:>2}) {g.get('subject') or '(sem nome)'}  [{g.get('size', '?')} pessoas]")
open('/tmp/grupos.txt', 'w').write('\n'.join(g['id'] for g in d))
raise SystemExit(0 if d else 1)
PY
atual_nums=""
if [ -n "${GRUPOS:-}" ]; then
  atual_nums=$(python3 -c "
ids=open('/tmp/grupos.txt').read().split(); sel='$GRUPOS'.split(',')
print(','.join(str(i+1) for i,g in enumerate(ids) if g in sel))")
fi
nums=$(pergunta "Numero do grupo de ocorrencias (varios: 1,3)" "$atual_nums")
GRUPOS=$(python3 -c "
ids=open('/tmp/grupos.txt').read().split()
sel=[ids[int(x)-1] for x in '$nums'.split(',') if x.strip().isdigit() and 0<int(x)<=len(ids)]
print(','.join(sel))")
[ -n "$GRUPOS" ] || erro "Nenhum grupo valido escolhido."
ok "Grupo(s): $GRUPOS"

cat > config.env <<CFG
SUPABASE_URL=$SUPABASE_URL
SUPABASE_KEY=$SUPABASE_KEY
GEMINI_KEY=$GEMINI_KEY
GEMINI_MODEL=$GEMINI_MODEL
GRUPOS=$GRUPOS
INSTANCIA=$INSTANCIA
CFG
chmod 600 config.env

echo; echo "=== 4/4 Ativando o fluxo no n8n ==="
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$RAW/fluxo-ocorrencias.json" -o "$TMP/modelo.json" || erro "Nao consegui baixar o fluxo do GitHub"
curl -fsSL "$RAW/fluxo-avisos.json" -o "$TMP/avisos.json" || erro "Nao consegui baixar o fluxo de avisos do GitHub"
export SUPABASE_URL SUPABASE_KEY GEMINI_KEY GEMINI_MODEL GRUPOS EVO_API_KEY TMP INSTANCIA
python3 - <<'PY'
import json, os
e = os.environ
s = open(f"{e['TMP']}/modelo.json").read()
for k, v in {'__GRUPOS__': e['GRUPOS'], '__SUPABASE_URL__': e['SUPABASE_URL'], '__EVOLUTION_URL__': 'http://evolution:8080',
             '__GEMINI_URL__': f"https://generativelanguage.googleapis.com/v1beta/models/{e['GEMINI_MODEL']}:generateContent"}.items():
    s = s.replace(k, v)
os.makedirs(f"{e['TMP']}/imp", exist_ok=True)
open(f"{e['TMP']}/imp/fluxo.json", 'w').write(s)
# fluxo 2: responde no grupo quando a ocorrencia e resolvida (liga/desliga na tabela whatsapp_avisos do Supabase)
a = open(f"{e['TMP']}/avisos.json").read()
for k, v in {'__SUPABASE_URL__': e['SUPABASE_URL'], '__EVOLUTION_URL__': 'http://evolution:8080', '__INSTANCIA__': e['INSTANCIA']}.items():
    a = a.replace(k, v)
open(f"{e['TMP']}/imp/avisos.json", 'w').write(a)
cred = lambda i, n, h, v: {"id": i, "name": n, "type": "httpHeaderAuth", "data": {"name": h, "value": v}}
json.dump([cred("credEvolution001", "Evolution API", "apikey", e['EVO_API_KEY']),
           cred("credSupabase0001", "Supabase (chave secreta)", "apikey", e['SUPABASE_KEY']),
           cred("credGeminiKey001", "Gemini", "x-goog-api-key", e['GEMINI_KEY'])],
          open(f"{e['TMP']}/imp/credenciais.json", 'w'))
PY
chmod -R a+rX "$TMP/imp"
$DC cp "$TMP/imp" n8n:/tmp/ocorr-imp >/dev/null
$DC exec -T n8n n8n import:credentials --input=/tmp/ocorr-imp/credenciais.json
$DC exec -T n8n n8n import:workflow --input=/tmp/ocorr-imp/fluxo.json
$DC exec -T n8n sh -c "n8n publish:workflow --id=$WF_ID 2>/dev/null || n8n update:workflow --id=$WF_ID --active=true"
$DC exec -T n8n n8n import:workflow --input=/tmp/ocorr-imp/avisos.json
$DC exec -T n8n sh -c "n8n publish:workflow --id=ocorrAvisos00001 2>/dev/null || n8n update:workflow --id=ocorrAvisos00001 --active=true"
$DC exec -T -u root n8n rm -rf /tmp/ocorr-imp || $DC exec -T n8n rm -rf /tmp/ocorr-imp || true
info "Reiniciando o n8n para ligar o fluxo..."
$DC restart n8n >/dev/null
for i in $(seq 1 40); do
  r=$(curl -s --max-time 5 -X POST -H 'Content-Type: application/json' -d '{"event":"teste"}' \
      http://127.0.0.1:5678/webhook/whatsapp-ocorrencias 2>&1 || true)
  [[ "$r" == *"started"* || "$r" == *"{"* ]] && [[ "$r" != *"404"* ]] && break
  sleep 3
done
if [[ "$r" == *"404"* || -z "$r" ]]; then
  aviso "O fluxo foi importado mas nao respondeu ativo. Abra o n8n, entre em 'Ocorrencias do WhatsApp' e ligue o botao Active/Publish."
else
  ok "Fluxo ativo e recebendo mensagens"
fi
echo
echo "Pronto! Teste: mande no grupo  ->  teste: carro 99 nao carrega"
echo "Avisos de resolucao no grupo: fluxo ativo, mas so envia depois de ligar no Supabase (SQL Editor):"
echo "   update public.whatsapp_avisos set ligado = true;"
echo "Em 1 minuto deve aparecer no painel (aba Ocorrencias) e na Central da Frota (bloco Fluxos)."
