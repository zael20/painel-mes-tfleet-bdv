#!/bin/bash
# Liga o aviso no WhatsApp da página "Visitas aos carros" (gestao-integrada.github.io/visitas).
# Uso na TV Box:  curl -fsSL https://raw.githubusercontent.com/zael20/painel-mes-tfleet-bdv/main/servidor-tvbox/visitas-whatsapp.sh | sudo bash
# Usa as credenciais que já existem no n8n (Evolution API e Supabase chave secreta) e o chip do robô.
set -e
DIR=/opt/servidor
DC="docker compose -f $DIR/docker-compose.yml --project-directory $DIR"
RAW=https://raw.githubusercontent.com/zael20/painel-mes-tfleet-bdv/main/servidor-tvbox
INST=$(find "$DIR" -maxdepth 3 -name config.env -exec grep -h '^INSTANCIA=' {} + 2>/dev/null </dev/null | head -1 | cut -d= -f2 || true)
INST=${INST:-frota}
echo "Instância do WhatsApp: $INST"
TMP=$(mktemp -d)
curl -fsSL "$RAW/fluxo-visitas-whatsapp.json" | sed "s/__INSTANCIA__/$INST/g" > "$TMP/visitas.json"
chmod a+r "$TMP/visitas.json"
$DC cp "$TMP/visitas.json" n8n:/tmp/visitas.json >/dev/null
$DC exec -T n8n n8n import:workflow --input=/tmp/visitas.json
$DC exec -T n8n sh -c "n8n publish:workflow --id=visitasWhats0001 2>/dev/null || n8n update:workflow --id=visitasWhats0001 --active=true"
rm -rf "$TMP"
echo "Reiniciando o n8n..."
$DC restart n8n >/dev/null
echo
echo "PRONTO. Fluxo 'Visitas — WhatsApp para o Mizael' ligado (roda a cada 1 minuto)."
echo "Confira se o seu número está em Visitas aos carros -> Ajustes -> Seu WhatsApp."
