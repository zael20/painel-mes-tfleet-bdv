#!/usr/bin/env bash
# Instalador do servidor da TV Box (Monitor Frota).
# Sobe, com Docker: n8n (todos os fluxos) + Evolution API (WhatsApp) + banco + Redis.
# E instala: Cockpit (interface web com terminal), Tailscale (acesso de qualquer lugar sem abrir porta),
# backup diario dos fluxos e o comando "servidor" (status, logs, backup, atualizar...).
# Uso na box (Armbian/Debian/Ubuntu, ARM ou x86):  curl -fsSL <RAW>/instalar.sh | sudo bash
# Pode rodar de novo: nao apaga dados nem troca as senhas ja criadas.
set -euo pipefail

DIR=/opt/servidor
RAW="${RAW:-https://raw.githubusercontent.com/zael20/painel-mes-tfleet-bdv/main/servidor-tvbox}"
EVOLUTION_TAG="${EVOLUTION_TAG:-v2.3.7}"   # se o QR code nao aparecer, rode de novo com EVOLUTION_TAG=latest
N8N_TAG="${N8N_TAG:-2.45.3}"

ok()   { echo -e "\e[32m[OK]\e[0m $*"; }
info() { echo -e "\e[36m[..]\e[0m $*"; }
aviso(){ echo -e "\e[33m[!]\e[0m $*"; }
erro() { echo -e "\e[31m[ERRO]\e[0m $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || erro "Rode com sudo:  sudo bash instalar.sh"

# ------------------------------------------------------------------ 1. memoria e fuso
RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
ok "Memoria RAM real desta box: ${RAM_MB} MB"
if [ "$RAM_MB" -lt 1500 ]; then
  aviso "Pouca RAM (menos de 1,5 GB). Vai funcionar, mas mais devagar; o servidor fica no modo enxuto."
fi
# swap em arquivo so quando a RAM e curta (gravar swap no cartao SD desgasta o cartao)
if [ "$RAM_MB" -lt 3000 ] && ! swapon --show | grep -q '/swapfile'; then
  info "Criando swap de 2 GB..."
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw,pri=-2 0 0' >> /etc/fstab
  sysctl -q vm.swappiness=10; echo 'vm.swappiness=10' > /etc/sysctl.d/99-servidor.conf
fi
timedatectl set-timezone America/Belem 2>/dev/null || true
ok "Fuso horario: America/Belem"

# ------------------------------------------------------------------ 2. pacotes, Docker, Cockpit
info "Atualizando o sistema e instalando Docker e Cockpit (pode levar 5 a 15 minutos)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl openssl ca-certificates python3 cron >/dev/null
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh >/dev/null
fi
systemctl enable --now docker >/dev/null 2>&1
docker compose version >/dev/null || erro "docker compose nao instalou"
ok "Docker $(docker --version | awk '{print $3}' | tr -d ,)"

# sem cockpit-networkmanager de proposito: ele instala o NetworkManager, que pode brigar com a rede do cabo
apt-get install -y -qq --no-install-recommends cockpit cockpit-system cockpit-ws cockpit-bridge >/dev/null
apt-get install -y -qq --no-install-recommends bluez >/dev/null 2>&1 || true
systemctl enable --now cockpit.socket >/dev/null 2>&1
ok "Cockpit instalado (interface web na porta 9090)"

# ------------------------------------------------------------------ 3. Tailscale (acesso de fora sem abrir porta)
if ! command -v tailscale >/dev/null; then
  info "Instalando o Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
fi
systemctl enable --now tailscaled >/dev/null 2>&1
ok "Tailscale instalado"

# ------------------------------------------------------------------ 4. configuracao dos servicos
mkdir -p "$DIR/backups" "$DIR/importar" "$DIR/codigos" && cd "$DIR"
gen() { openssl rand -hex 24; }
if [ ! -f segredos.env ]; then
  cat > segredos.env <<SEG
EVO_API_KEY=$(gen)
PG_PASSWORD=$(gen)
N8N_ENCRYPTION_KEY=$(gen)
SEG
  chmod 600 segredos.env
fi
# shellcheck disable=SC1091
source segredos.env

IP_LAN=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
[ -n "$IP_LAN" ] || IP_LAN=$(hostname -I | awk '{print $1}')

cat > .env <<ENV
EVOLUTION_TAG=$EVOLUTION_TAG
N8N_TAG=$N8N_TAG
PG_PASSWORD=$PG_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
IP_LAN=$IP_LAN
EVO_URL=http://127.0.0.1:8080
N8N_LOCAL=http://127.0.0.1:5678
ENV
chmod 600 .env

cat > evolution.env <<EVO
SERVER_TYPE=http
SERVER_PORT=8080
SERVER_URL=http://$IP_LAN:8080
AUTHENTICATION_API_KEY=$EVO_API_KEY
AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES=true
DEL_INSTANCE=false
LOG_LEVEL=ERROR,WARN,INFO
LOG_COLOR=false
CONFIG_SESSION_PHONE_CLIENT=Monitor Frota
CONFIG_SESSION_PHONE_NAME=Chrome
QRCODE_LIMIT=30

DATABASE_PROVIDER=postgresql
DATABASE_CONNECTION_URI=postgresql://evolution:$PG_PASSWORD@postgres:5432/evolution?schema=evolution_api
DATABASE_CONNECTION_CLIENT_NAME=evolution
DATABASE_SAVE_DATA_INSTANCE=true
DATABASE_SAVE_DATA_NEW_MESSAGE=true
DATABASE_SAVE_MESSAGE_UPDATE=false
DATABASE_SAVE_DATA_CONTACTS=true
DATABASE_SAVE_DATA_CHATS=true
DATABASE_SAVE_DATA_LABELS=false
DATABASE_SAVE_DATA_HISTORIC=false

CACHE_REDIS_ENABLED=true
CACHE_REDIS_URI=redis://redis:6379/6
CACHE_REDIS_PREFIX_KEY=evolution
CACHE_REDIS_SAVE_INSTANCES=false
CACHE_LOCAL_ENABLED=false

# Toda mensagem nova vai para o n8n pela rede interna do Docker (nao passa pela internet)
WEBHOOK_GLOBAL_ENABLED=true
WEBHOOK_GLOBAL_URL=http://n8n:5678/webhook/whatsapp-ocorrencias
WEBHOOK_GLOBAL_WEBHOOK_BY_EVENTS=false
WEBHOOK_EVENTS_APPLICATION_STARTUP=false
WEBHOOK_EVENTS_QRCODE_UPDATED=false
WEBHOOK_EVENTS_MESSAGES_SET=false
WEBHOOK_EVENTS_MESSAGES_UPSERT=true
WEBHOOK_EVENTS_MESSAGES_EDITED=false
WEBHOOK_EVENTS_MESSAGES_UPDATE=false
WEBHOOK_EVENTS_MESSAGES_DELETE=false
WEBHOOK_EVENTS_SEND_MESSAGE=false
WEBHOOK_EVENTS_SEND_MESSAGE_UPDATE=false
WEBHOOK_EVENTS_CONTACTS_SET=false
WEBHOOK_EVENTS_CONTACTS_UPSERT=false
WEBHOOK_EVENTS_CONTACTS_UPDATE=false
WEBHOOK_EVENTS_PRESENCE_UPDATE=false
WEBHOOK_EVENTS_CHATS_SET=false
WEBHOOK_EVENTS_CHATS_UPSERT=false
WEBHOOK_EVENTS_CHATS_UPDATE=false
WEBHOOK_EVENTS_CHATS_DELETE=false
WEBHOOK_EVENTS_GROUPS_UPSERT=false
WEBHOOK_EVENTS_GROUPS_UPDATE=false
WEBHOOK_EVENTS_GROUP_PARTICIPANTS_UPDATE=false
WEBHOOK_EVENTS_CONNECTION_UPDATE=true
WEBHOOK_EVENTS_LABELS_EDIT=false
WEBHOOK_EVENTS_LABELS_ASSOCIATION=false
WEBHOOK_EVENTS_CALL=false
WEBHOOK_EVENTS_ERRORS=false
EVO
chmod 600 evolution.env

# Portas so na rede de casa e na rede privada do Tailscale (o roteador nao repassa nada da internet).
# O trafego pelo Tailscale ja vai criptografado, por isso o n8n roda em http.
cat > docker-compose.yml <<'YML'
x-log: &log
  driver: json-file
  options: { max-size: "10m", max-file: "3" }

services:
  n8n:
    image: n8nio/n8n:${N8N_TAG}
    restart: unless-stopped
    ports: ["5678:5678"]
    environment:
      N8N_PORT: "5678"
      N8N_PROTOCOL: http
      N8N_SECURE_COOKIE: "false"
      WEBHOOK_URL: http://${IP_LAN}:5678/
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      GENERIC_TIMEZONE: America/Belem
      TZ: America/Belem
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_PERSONALIZATION_ENABLED: "false"
      # o alerta roda a cada 5 min: guardar so as execucoes com erro para nao encher o cartao
      EXECUTIONS_DATA_SAVE_ON_SUCCESS: none
      EXECUTIONS_DATA_SAVE_ON_ERROR: all
      EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS: "true"
      EXECUTIONS_DATA_PRUNE: "true"
      EXECUTIONS_DATA_MAX_AGE: "168"
      N8N_DEFAULT_BINARY_DATA_MODE: filesystem
    volumes:
      - n8n_data:/home/node/.n8n
      - ./importar:/importar
      - ./backups:/backups
    logging: *log

  evolution:
    image: evoapicloud/evolution-api:${EVOLUTION_TAG}
    restart: unless-stopped
    ports: ["8080:8080"]
    env_file: evolution.env
    depends_on: [postgres, redis]
    volumes:
      - evolution_instances:/evolution/instances
    logging: *log

  postgres:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: evolution
      POSTGRES_USER: evolution
      POSTGRES_PASSWORD: ${PG_PASSWORD}
    command: postgres -c shared_buffers=64MB -c max_connections=40
    volumes:
      - postgres_data:/var/lib/postgresql/data
    logging: *log

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --appendonly yes --maxmemory 64mb --maxmemory-policy allkeys-lru
    volumes:
      - redis_data:/data
    logging: *log

volumes:
  evolution_instances:
  postgres_data:
  redis_data:
  n8n_data:
YML
chown -R 1000:1000 importar backups

# ------------------------------------------------------------------ 5. comando "servidor" e backup diario
curl -fsSL "$RAW/servidor" -o /usr/local/bin/servidor && chmod 755 /usr/local/bin/servidor \
  || aviso "Nao consegui baixar o comando 'servidor' (o resto funciona). Rode de novo depois."
curl -fsSL "$RAW/configurar-whatsapp.sh" -o "$DIR/configurar-whatsapp.sh" \
  || aviso "Nao consegui baixar o configurar-whatsapp.sh. Rode de novo depois."
mkdir -p /usr/share/cockpit/central
for f in manifest.json index.html central.css central.js; do
  curl -fsSL "$RAW/central/$f" -o "/usr/share/cockpit/central/$f" || aviso "Nao consegui baixar a Central ($f)."
done
ok "Central da Frota instalada no Cockpit"
cat > /etc/cron.d/servidor-backup <<'CRON'
# backup dos fluxos e credenciais (criptografadas) todo dia as 03:00
0 3 * * * root /usr/local/bin/servidor backup >/var/log/servidor-backup.log 2>&1
CRON
ok "Backup diario agendado (03:00, guarda 14 dias em $DIR/backups)"

# ------------------------------------------------------------------ 6. subir tudo
info "Baixando as imagens e iniciando (na primeira vez leva 5 a 15 minutos numa TV Box)..."
docker compose pull -q
docker compose up -d

info "Aguardando os servicos responderem..."
e=""; n=""
for i in $(seq 1 90); do
  e=$(curl -s --max-time 3 http://127.0.0.1:8080 | head -c 200 || true)
  n=$(curl -s --max-time 3 http://127.0.0.1:5678/healthz || true)
  [[ -n "$e" && "$n" == *ok* ]] && break
  sleep 5
done
[[ -n "$e" ]] && ok "Evolution API respondendo" || aviso "Evolution ainda nao respondeu. Veja: servidor logs evolution"
[[ "$n" == *ok* ]] && ok "n8n respondendo" || aviso "n8n ainda nao respondeu. Veja: servidor logs n8n"

# ------------------------------------------------------------------ 7. ligar o Tailscale (login pelo navegador)
TS_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
if [ -z "$TS_IP" ]; then
  echo
  info "Agora ligue o Tailscale: abra o link que aparecer abaixo e entre com a MESMA conta do celular/PC."
  tailscale up --hostname=servidor-frota --timeout=10m || aviso "Tailscale nao concluiu. Depois rode: sudo tailscale up --hostname=servidor-frota"
  TS_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
fi

cat > ACESSOS.txt <<ACC
=== Servidor da TV Box (Monitor Frota) ===
                      Em casa                        De qualquer lugar (app Tailscale ligado)
Interface (Cockpit):  https://$IP_LAN:9090          https://${TS_IP:-<ip-tailscale>}:9090
n8n (fluxos):         http://$IP_LAN:5678           http://${TS_IP:-<ip-tailscale>}:5678
WhatsApp (Evolution): http://$IP_LAN:8080/manager   http://${TS_IP:-<ip-tailscale>}:8080/manager
Chave da Evolution:   $EVO_API_KEY

Login do Cockpit = o usuario e senha que voce criou no primeiro boot do Armbian (nao o root).
O Cockpit avisa "conexao nao segura" na 1a vez: clique em Avancado > Continuar (o certificado e da propria box).
Comando de ajuda no terminal:  servidor
Ver de novo:  sudo cat $DIR/ACESSOS.txt
ACC
chmod 600 ACESSOS.txt
echo
cat ACESSOS.txt
echo
ok "Pronto. Proximo passo: abrir o n8n, criar o usuario dono e importar os fluxos."
echo "Para o WhatsApp: leia o QR em http://$IP_LAN:8080/manager e depois rode:  sudo servidor whatsapp"
