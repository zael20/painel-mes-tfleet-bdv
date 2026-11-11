#!/usr/bin/env bash
# Descobre a configuracao da telinha de LED da frente da TV Box (OpenVFD do Armbian ophub).
# Testa as ligacoes conhecidas de TV Box S905X/Tanix uma por uma e pergunta o que apareceu.
# Uso:  sudo bash <(curl -fsSL RAW/telinha-testar.sh)
# A que funcionar fica salva em /opt/servidor/telinha.conf (e em /usr/share/openvfd/conf/diy.conf = box 99).
set -u
[ "$(id -u)" -eq 0 ] || { echo "Use com sudo"; exit 1; }
CONF=/usr/share/openvfd/conf
[ -x /usr/sbin/armbian-openvfd ] || { echo "armbian-openvfd nao encontrado (Armbian sem OpenVFD)"; exit 1; }

# nome | clk | dat | stb | chars | dot_bits | display_type
CANDIDATOS=(
  "Tanix TX3-mini (pinos -1)|0,75,0|0,74,0|1,4,0|4,3,2,1,0|0,1,3,2,4,5,6|0x01,0x00,0x00,0x00"
  "Tanix TX3-mini|0,76,0|0,75,0|1,4,0|4,3,2,1,0|0,1,3,2,4,5,6|0x01,0x00,0x00,0x00"
  "Tanix TX9 Pro (pinos -1)|0,75,0|0,74,0|0,53,0|4,0,1,2,3|0,1,2,3,4,5,6|0x00,0x00,0x00,0x00"
  "Tanix TX9 Pro|0,76,0|0,75,0|0,53,0|4,0,1,2,3|0,1,2,3,4,5,6|0x00,0x00,0x00,0x00"
  "Tanix (pinos -1, tipo 0)|0,75,0|0,74,0|1,4,0|4,0,1,2,3|0,1,2,3,4,5,6|0x00,0x00,0x00,0x00"
  "T95m S905X v1|1,5,0|1,4,0|1,3,0|0,1,2,3,4|0,1,2,3,4,5,6|0x01,0x00,0x00,0x00"
  "T95m S905X v2|1,4,0|1,3,0|1,2,0|0,1,2,3,4|0,1,2,3,4,5,6|0x01,0x00,0x00,0x00"
)

escrever() {  # $1 = linha do candidato
  IFS='|' read -r nome clk dat stb chars dots tipo <<<"$1"
  cat > "$CONF/diy.conf" <<C
# Telinha da TV Box - $nome (achado por telinha-testar.sh)
vfd_gpio_clk='$clk'
vfd_gpio_dat='$dat'
vfd_gpio_stb='$stb'
vfd_chars='$chars'
vfd_dot_bits='$dots'
vfd_display_type='$tipo'
functions='usb colon eth'
C
}

n=0
for c in "${CANDIDATOS[@]}"; do
  n=$((n + 1))
  escrever "$c"
  armbian-openvfd 0 >/dev/null 2>&1; sleep 1
  armbian-openvfd 99 >/dev/null 2>&1 &
  sleep 5
  echo
  echo "Teste $n de ${#CANDIDATOS[@]}: ${c%%|*}"
  echo "  OLHE A TELINHA.  s = mostra a hora certinho   e = acende, mas embaralhado/de ponta-cabeca   n = nada"
  read -r -p "  O que apareceu? (s/e/n) " r
  case "$r" in
    s|S) cp "$CONF/diy.conf" /opt/servidor/telinha.conf
         echo; echo "[OK] Achou! Configuracao salva em /opt/servidor/telinha.conf (box 99). Mande print desta tela."
         exit 0 ;;
    e|E) cp "$CONF/diy.conf" "/opt/servidor/telinha-quase-$n.conf"
         echo "  anotado como 'quase' (telinha-quase-$n.conf) - continuando..." ;;
  esac
done
armbian-openvfd 0 >/dev/null 2>&1
echo; echo "Nenhum mostrou a hora certinho. Mande print desta tela e uma foto do chip ao lado da telinha."
ls /opt/servidor/telinha-quase-*.conf 2>/dev/null
