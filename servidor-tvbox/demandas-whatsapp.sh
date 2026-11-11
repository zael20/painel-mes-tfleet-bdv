#!/bin/bash
# Liga o WhatsApp automático do quadro de Demandas (gestao-integrada.github.io/demandas).
# Uso na TV Box:  curl -fsSL https://raw.githubusercontent.com/zael20/painel-mes-tfleet-bdv/main/servidor-tvbox/demandas-whatsapp.sh | sudo bash
# Usa as credenciais que já existem no n8n (Evolution API e Supabase chave secreta) e o chip do robô.
set -e
DIR=/opt/servidor
DC="docker compose -f $DIR/docker-compose.yml --project-directory $DIR"
RAW=https://raw.githubusercontent.com/zael20/painel-mes-tfleet-bdv/main/servidor-tvbox
INST=$(find "$DIR" -maxdepth 3 -name config.env -exec grep -h '^INSTANCIA=' {} + 2>/dev/null </dev/null | head -1 | cut -d= -f2 || true)
INST=${INST:-frota}
echo "Instância do WhatsApp: $INST"
TMP=$(mktemp -d)
curl -fsSL "$RAW/fluxo-demandas-whatsapp.json" | sed "s/__INSTANCIA__/$INST/g" > "$TMP/demandas.json"
chmod a+r "$TMP/demandas.json"
$DC cp "$TMP/demandas.json" n8n:/tmp/demandas.json >/dev/null </dev/null
$DC exec -T n8n n8n import:workflow --input=/tmp/demandas.json </dev/null
if $DC exec -T n8n sh -c "n8n publish:workflow --id=demandasWhats01 || n8n update:workflow --id=demandasWhats01 --active=true" </dev/null; then
  LIGOU=1
else
  LIGOU=0
  echo "!! Não consegui ligar o fluxo pela linha de comando (veja a mensagem acima)."
fi
rm -rf "$TMP"
echo "Reiniciando o n8n..."
$DC restart n8n >/dev/null </dev/null
echo
if [ "$LIGOU" = 1 ]; then
  echo "PRONTO. Fluxo 'Demandas — WhatsApp automático' ligado (roda a cada 1 minuto)."
else
  echo "Fluxo importado, mas DESLIGADO: abra o n8n, entre em 'Demandas — WhatsApp automático' e ligue (Publish / Active)."
fi
echo "No quadro: Contatos e acessos -> coloque o seu celular (recebe as atualizações) e o celular de cada contato."
