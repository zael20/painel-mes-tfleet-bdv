#!/usr/bin/env python3
# Le a configuracao da telinha de LED (fd628/fd650/vfd) do Android que ficou na memoria interna (eMMC)
# da TV Box: procura os device trees (DTB) gravados la e mostra os nos da telinha e dos GPIOs.
# So LE a memoria interna, nao grava nada.  Uso: sudo python3 telinha-android.py
import gzip, os, struct, subprocess, sys, zlib

if os.geteuid() != 0:
    sys.exit("Use com sudo")

# --- driver no Armbian atual ---
mods = subprocess.run("find /lib/modules/$(uname -r) -name 'openvfd*'", shell=True, capture_output=True, text=True).stdout.strip()
print("Driver openvfd no kernel:", mods or "NAO ENCONTRADO")

# --- qual disco e a memoria interna (eMMC): o mmcblk que NAO tem a raiz montada ---
raiz = subprocess.run("findmnt -no SOURCE /", shell=True, capture_output=True, text=True).stdout.strip()
discos = [d for d in sorted(os.listdir("/dev")) if d.startswith("mmcblk") and d[6:].isdigit()]
emmc = [d for d in discos if not raiz.startswith("/dev/" + d)]
print("Raiz:", raiz, "| discos:", discos, "| memoria interna:", emmc)
if not emmc:
    sys.exit("Nao achei a memoria interna (eMMC).")

PALAVRAS = (b"fd628", b"fd650", b"vfd", b"aml_fd", b"led_", b"openvfd", b"tm16", b"aip")

def fdt_dump(blob):
    """Parser minimo de FDT: devolve [(caminho, prop, valor_bytes)] e mapa phandle->caminho."""
    _, total, off_struct, off_str = struct.unpack(">IIII", blob[:16])
    i, pilha, props, ph = off_struct, [], [], {}
    while i < len(blob):
        tok = struct.unpack(">I", blob[i:i + 4])[0]; i += 4
        if tok == 1:
            fim = blob.index(b"\0", i); pilha.append(blob[i:fim].decode(errors="replace")); i = (fim + 4) & ~3
        elif tok == 2:
            pilha.pop()
        elif tok == 3:
            ln, no = struct.unpack(">II", blob[i:i + 8]); i += 8
            nome = blob[off_str + no:blob.index(b"\0", off_str + no)].decode(errors="replace")
            val = blob[i:i + ln]; i = (i + ln + 3) & ~3
            caminho = "/".join(pilha)
            props.append((caminho, nome, val))
            if nome in ("phandle", "linux,phandle") and ln == 4:
                ph[struct.unpack(">I", val)[0]] = caminho
        elif tok == 9:
            break
    return props, ph

def mostrar(v):
    if v and v[:1] != b"\0" and v[-1:] == b"\0" and b"\0\0" not in v and all(32 <= c < 127 or c == 0 for c in v):
        return '"' + v.rstrip(b"\0").decode().replace("\0", '", "') + '"'
    if len(v) % 4 == 0:
        return "<" + " ".join(str(x) for x in struct.unpack(">%dI" % (len(v) // 4), v)) + ">"
    return v.hex()

def analisar(blob, origem):
    try:
        props, ph = fdt_dump(blob)
    except Exception:
        return False
    achou = [p for p in props if any(k in (p[0] + "/" + p[1]).lower().encode() for k in PALAVRAS)]
    if not achou:
        return False
    modelo = next((mostrar(v) for c, n, v in props if c == "" and n in ("model", "amlogic-dt-id")), "?")
    print("\n=== DTB em", origem, "| modelo:", modelo)
    for c, n, v in achou:
        print(f"  {c or '/'} : {n} = {mostrar(v)}")
    print("  -- phandles dos controladores de GPIO:")
    for k, c in sorted(ph.items()):
        if "pinctrl" in c or "gpio" in c.split("/")[-1] or "bank" in c:
            print(f"     {k} -> {c}")
    return True

def blobs(dados, base):
    """Acha DTBs soltos (d00dfeed) e dentro de gzip (multi-dtb da Amlogic)."""
    i = 0
    while True:
        i = dados.find(b"\xd0\x0d\xfe\xed", i)
        if i < 0: break
        total = struct.unpack(">I", dados[i + 4:i + 8])[0]
        if 200 < total < 2_000_000:
            yield base + i, dados[i:i + total]
        i += 4
    i = 0
    while True:
        i = dados.find(b"\x1f\x8b\x08", i)
        if i < 0: break
        try:
            d = zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(dados[i:i + 4_000_000], 8_000_000)
            for off, b in blobs_simples(d):
                yield f"{base + i:#x}(gzip)+{off:#x}", b
        except Exception:
            pass
        i += 3

def blobs_simples(d):
    i = 0
    while True:
        i = d.find(b"\xd0\x0d\xfe\xed", i)
        if i < 0: return
        total = struct.unpack(">I", d[i + 4:i + 8])[0]
        if 200 < total < 2_000_000: yield i, d[i:i + total]
        i += 4

vistos, achados = set(), 0
for disco in [] if "--textos" in sys.argv else emmc + [d + "boot0" for d in emmc if os.path.exists(f"/dev/{d}boot0")]:
    caminho = "/dev/" + disco
    print("\nLendo", caminho, "(primeiros 1,5 GB, pode levar 1-2 min)...")
    BLOCO, LIMITE, pos = 64 * 1048576, 1536 * 1048576, 0
    try:
        f = open(caminho, "rb")
    except OSError as e:
        print("  nao abriu:", e); continue
    sobra = b""
    while pos < LIMITE:
        dados = f.read(BLOCO)
        if not dados: break
        janela = sobra + dados
        for off, b in blobs(janela, pos - len(sobra)):
            h = hash(b)
            if h in vistos: continue
            vistos.add(h)
            if analisar(b, f"{disco} @ {off if isinstance(off, str) else hex(off)}"):
                achados += 1
        sobra = dados[-4_000_000:]
        pos += len(dados)
    f.close()

if "--textos" not in sys.argv:
  print("\nDTBs da telinha encontrados:", achados)
if not achados and "--textos" not in sys.argv:
    print("Nao achei. Mande print e eu sigo por outro caminho.")

# --- 2a passada: textos sobre a telinha no Android inteiro (modulo/servico do fabricante, u-boot) ---
import re
KWS = [b"fd628", b"fd650", b"FD628", b"FD650", b"tm1628", b"TM1628", b"openvfd", b"vfd_", b"_vfd", b"aml_led", b"led_dig"]
LIMPO = re.compile(rb"[ -~]+")
textos = {}
for disco in emmc + [d + "boot0" for d in emmc if os.path.exists(f"/dev/{d}boot0")]:
    print(f"\nProcurando textos da telinha em /dev/{disco}...", flush=True)
    tam = int(open(f"/sys/block/{disco}/size").read()) * 512 if os.path.exists(f"/sys/block/{disco}/size") else 0
    with open("/dev/" + disco, "rb") as f:
        sobra, lido = b"", 0
        while True:
            dados = f.read(32 * 1048576)
            if not dados: break
            lido += len(dados)
            bloco = sobra + dados
            for kw in KWS:                      # busca literal (rapida), depois pega o texto em volta
                i = bloco.find(kw)
                while i >= 0:
                    trecho = bloco[max(0, i - 40):i + 80]
                    for m in LIMPO.finditer(trecho):
                        if kw in m.group(0):
                            t = m.group(0).strip()
                            textos[t] = textos.get(t, 0) + 1
                    i = bloco.find(kw, i + len(kw))
            sobra = dados[-200:]
            if tam: print(f"\r  {100 * lido // tam}%", end="", flush=True)
print("\nTEXTOS encontrados (mais repetidos primeiro):")
for t, n in sorted(textos.items(), key=lambda x: -x[1])[:60]:
    print(f"  {n:4d}x  {t.decode(errors='replace')[:120]}")
