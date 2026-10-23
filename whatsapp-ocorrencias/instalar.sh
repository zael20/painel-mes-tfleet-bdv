#!/usr/bin/env bash
# Instalador do servidor de Ocorrencias do WhatsApp (Monitor Frota).
# Sobe, com Docker: Evolution API (le o grupo do WhatsApp) + n8n (fluxo com a IA) + Caddy (HTTPS gratis).
# Uso na VM (Ubuntu 22.04/24.04, ARM ou x86):  sudo bash instalar.sh
# Pode rodar de novo: nao apaga dados nem troca as senhas ja criadas.
set -euo pipefail

DIR=/opt/ocorrencias
EVOLUTION_TAG="${EVOLUTION_TAG:-v2.3.7}"   # se o QR code nao aparecer, rode de novo com EVOLUTION_TAG=latest
N8N_TAG="${N8N_TAG:-2.45.3}"

ok()   { echo -e "\e[32m[OK]\e[0m $*"; }
info() { echo -e "\e[36m[..]\e[0m $*"; }
erro() { echo -e "\e[31m[ERRO]\e[0m $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || erro "Rode com sudo:  sudo bash instalar.sh"

# ------------------------------------------------------------------ 1. memoria extra (swap 2 GB)
if ! swapon --show | grep -q .; then
  info "Criando swap de 2 GB (seguranca contra falta de memoria)..."
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
ok "Swap ativo"

# ------------------------------------------------------------------ 2. pacotes e Docker
info "Atualizando o sistema e instalando o Docker (pode levar alguns minutos)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl openssl ca-certificates iptables-persistent >/dev/null 2>&1 || apt-get install -y -qq curl openssl ca-certificates >/dev/null
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh >/dev/null
fi
systemctl enable --now docker >/dev/null 2>&1
docker compose version >/dev/null || erro "docker compose nao instalou"
ok "Docker $(docker --version | awk '{print $3}' | tr -d ,)"

# ------------------------------------------------------------------ 3. firewall interno da VM (imagens da Oracle bloqueiam 80/443)
for p in 80 443; do
  if ! iptables -C INPUT -p tcp --dport $p -m state --state NEW -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 5 -p tcp --dport $p -m state --state NEW -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $p -j ACCEPT
  fi
done
command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1 || true
ok "Portas 80 e 443 liberadas no firewall da VM"

# ------------------------------------------------------------------ 4. endereco publico -> nomes com HTTPS (sslip.io, sem comprar dominio)
IP=$(curl -4 -fsS --max-time 10 https://api.ipify.org || curl -4 -fsS --max-time 10 https://ifconfig.me || true)
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || erro "Nao consegui descobrir o IP publico da VM"
BASE="${IP//./-}.sslip.io"
N8N_HOST="n8n.$BASE"
EVO_HOST="evo.$BASE"
ok "IP publico: $IP"

# ------------------------------------------------------------------ 5. arquivos de configuracao
mkdir -p "$DIR" && cd "$DIR"
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

cat > .env <<ENV
EVOLUTION_TAG=$EVOLUTION_TAG
N8N_TAG=$N8N_TAG
N8N_HOST=$N8N_HOST
EVO_HOST=$EVO_HOST
PG_PASSWORD=$PG_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
ENV
chmod 600 .env

cat > evolution.env <<EVO
SERVER_TYPE=http
SERVER_PORT=8080
SERVER_URL=https://$EVO_HOST
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

cat > Caddyfile <<CAD
$N8N_HOST {
	reverse_proxy n8n:5678
}
$EVO_HOST {
	reverse_proxy evolution:8080
}
CAD

cat > docker-compose.yml <<'YML'
x-log: &log
  driver: json-file
  options: { max-size: "10m", max-file: "3" }

services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
    logging: *log

  evolution:
    image: evoapicloud/evolution-api:${EVOLUTION_TAG}
    restart: unless-stopped
    env_file: evolution.env
    depends_on: [postgres, redis]
    volumes:
      - evolution_instances:/evolution/instances
    logging: *log

  postgres:
    image: postgres:15
    restart: unless-stopped
    environment:
      POSTGRES_DB: evolution
      POSTGRES_USER: evolution
      POSTGRES_PASSWORD: ${PG_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    logging: *log

  redis:
    image: redis:7
    restart: unless-stopped
    command: redis-server --appendonly yes --maxmemory 128mb --maxmemory-policy allkeys-lru
    volumes:
      - redis_data:/data
    logging: *log

  n8n:
    image: n8nio/n8n:${N8N_TAG}
    restart: unless-stopped
    environment:
      N8N_HOST: ${N8N_HOST}
      N8N_PROTOCOL: https
      N8N_PORT: "5678"
      WEBHOOK_URL: https://${N8N_HOST}/
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      GENERIC_TIMEZONE: America/Belem
      TZ: America/Belem
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_PERSONALIZATION_ENABLED: "false"
      EXECUTIONS_DATA_PRUNE: "true"
      EXECUTIONS_DATA_MAX_AGE: "168"
      N8N_DEFAULT_BINARY_DATA_MODE: filesystem
    volumes:
      - n8n_data:/home/node/.n8n
    logging: *log

volumes:
  caddy_data:
  evolution_instances:
  postgres_data:
  redis_data:
  n8n_data:
YML

# ------------------------------------------------------------------ 6. subir tudo
info "Baixando as imagens e iniciando (na primeira vez leva 3 a 8 minutos)..."
docker compose pull -q
docker compose up -d

info "Aguardando os servicos responderem..."
for i in $(seq 1 60); do
  e=$(docker compose exec -T caddy wget -qO- http://evolution:8080 2>/dev/null | head -c 200 || true)
  n=$(docker compose exec -T caddy wget -qO- http://n8n:5678/healthz 2>/dev/null || true)
  [[ -n "$e" && "$n" == *ok* ]] && break
  sleep 5
done
[[ -n "${e:-}" ]] && ok "Evolution API respondendo" || echo "[!] Evolution ainda nao respondeu. Veja: sudo docker compose -f $DIR/docker-compose.yml logs --tail 50 evolution"
[[ "${n:-}" == *ok* ]] && ok "n8n respondendo" || echo "[!] n8n ainda nao respondeu. Veja: sudo docker compose -f $DIR/docker-compose.yml logs --tail 50 n8n"

cat > ACESSOS.txt <<ACC
=== Servidor de Ocorrencias do WhatsApp ===
n8n (fluxo da IA):        https://$N8N_HOST
Evolution (WhatsApp):     https://$EVO_HOST/manager
Chave da Evolution:       $EVO_API_KEY
Webhook interno (ja configurado): http://n8n:5678/webhook/whatsapp-ocorrencias
Pasta: $DIR   |  Ver de novo:  sudo cat $DIR/ACESSOS.txt
ACC
chmod 600 ACESSOS.txt
echo
cat ACESSOS.txt
echo
ok "Pronto. Guarde a chave da Evolution num lugar seguro (nao mande no grupo)."
echo "Obs.: o HTTPS pode levar 1-2 minutos para ficar valido na primeira vez."
