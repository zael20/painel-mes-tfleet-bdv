#!/usr/bin/env python3
# Importa o HISTORICO do grupo de ocorrencias a partir da conversa exportada do WhatsApp.
# Uso na TV Box:  sudo servidor retroativo [dias]     (padrao: 60 dias; le o .zip/.txt mais novo de /opt/servidor/importar)
#
# Aceita a exportacao "sem midia" (.txt) ou "incluir midia" (.zip). Com midia, cada audio/foto/video do periodo
# passa antes pelo Gemini (transcricao/descricao curta, guardada em importar/.retro-midias.json para nao repetir).
#
# Para cada dia: manda as mensagens do dia para o Gemini (1 chamada por dia, cabe na cota gratis), que devolve as
# ocorrencias daquele dia; grava no Supabase com origem = 'retroativo'. O que foi resolvido no proprio grupo vira
# 'resolvida'; o resto vira 'historico' (aconteceu, mas o grupo nao registrou o desfecho) e nao entra como aberta.
# As mensagens brutas vao para whatsapp_msgs (id "retro:..."), para consulta. Pode rodar de novo: continua de onde parou.
import base64, hashlib, json, os, re, sys, time, urllib.error, urllib.request, zipfile
from datetime import datetime, timedelta, timezone

DIR = os.environ.get("DIR", "/opt/servidor")
SB = os.environ["SUPABASE_URL"].rstrip("/")
SB_KEY = os.environ["SUPABASE_KEY"]
GEM_KEY = os.environ["GEMINI_KEY"]
GEM_MODEL = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash-lite")
GRUPO = (os.environ.get("GRUPOS", "") or "retroativo").split(",")[0]
BELEM = timezone(timedelta(hours=-3))
ESTADO = os.path.join(DIR, "importar", ".retroativo-feito")
CACHE_MIDIA = os.path.join(DIR, "importar", ".retro-midias.json")
MAX_MIDIA = 19 * 1024 * 1024  # limite do envio direto ao Gemini (20 MB)
TIPOS_MIDIA = {"opus": ("audio", "audio/ogg"), "ogg": ("audio", "audio/ogg"), "m4a": ("audio", "audio/mp4"),
               "mp3": ("audio", "audio/mpeg"), "aac": ("audio", "audio/aac"), "wav": ("audio", "audio/wav"),
               "mp4": ("video", "video/mp4"), "3gp": ("video", "video/3gpp"), "mov": ("video", "video/quicktime"),
               "jpg": ("imagem", "image/jpeg"), "jpeg": ("imagem", "image/jpeg"), "png": ("imagem", "image/png"),
               "webp": ("imagem", "image/webp")}
CATEGORIAS = ["carregamento", "abrir_viagem", "contagem_passageiros", "internet_chip", "celular_defeito",
              "suporte", "som_musica", "outro"]


def ok(m): print(f"\033[32m[OK]\033[0m {m}", flush=True)
def info(m): print(f"\033[36m[..]\033[0m {m}", flush=True)
def aviso(m): print(f"\033[33m[!]\033[0m {m}", flush=True)
def erro(m): print(f"\033[31m[ERRO]\033[0m {m}", flush=True); sys.exit(1)


# ---------------------------------------------------------------- leitura do .txt exportado (Android e iPhone)
# Formatos aceitos (Android e iPhone, varios idiomas): "29/10/2026 14:32 - Nome: msg", "[29/10/26, 14:32:05] Nome: msg",
# "10/29/26, 2:32 PM - Nome: msg", "2026-10-29 14:32 - Nome: msg", "29.10.26, 14:32 - ..."
RE_LINHA = re.compile(r"^\[?(\d{1,4})[/.\-](\d{1,2})[/.\-](\d{2,4}),?\s+(\d{1,2})[:.](\d{2})(?:[:.](\d{2}))?"
                      r"\s*([AaPp]\.?\s?[Mm]\.?)?\]?\s*(?:[-–]\s+)?(.*)$")
# arquivo anexado: Android "PTT-2026...-WA0001.opus (arquivo anexado)"; iPhone "<anexado: 00000012-AUDIO-....opus>"
ANEXO = re.compile(r"^(?:<(?:anexado|attached):\s*(?P<a>[^>]+)>|(?P<b>\S+\.\w{2,5}) \((?:arquivo anexado|file attached)\))\s*(?P<leg>.*)$",
                   re.S | re.I)
MIDIA = re.compile(r"m[ií]dia oculta|arquivo de m[ií]dia oculto|omitid[oa]|ocultad[oa]|\(arquivo anexado\)|"
                   r"<attached:|media omitted|imagem ocultada|figurinha omitida", re.I)


def ler_conversa(caminho, pasta_midia=None):
    msgs = []
    for linha in open(caminho, encoding="utf-8-sig", errors="replace"):
        linha = linha.replace("‎", "").replace(" ", " ").rstrip("\r\n")
        m = RE_LINHA.match(linha)
        if not m:
            if msgs and linha.strip():
                msgs[-1]["texto"] = (msgs[-1]["texto"] + "\n" + linha.strip()).strip()[:4000]  # continuacao da mensagem
            continue
        a, b, c, hh, mi, ss, ampm, resto = m.groups()
        if len(a) == 4:
            ano, mes, d = int(a), int(b), int(c)          # 2026-10-29
        else:
            d, mes, ano = int(a), int(b), int(c)          # 29/10/2026
            if mes > 12 and d <= 12:
                d, mes = mes, d                           # 10/29/2026 (formato americano)
        ano += 2000 if ano < 100 else 0
        hh = int(hh)
        if ampm:
            hh = hh % 12 + (12 if ampm.lower().startswith("p") else 0)
        try:
            local = datetime(ano, mes, d, hh, int(mi), int(ss or 0), tzinfo=BELEM)
        except ValueError:
            continue
        if ": " not in resto:
            continue  # aviso do sistema (entrou, saiu, mudou o nome do grupo...)
        autor, texto = resto.split(": ", 1)
        texto = texto.strip()
        an = ANEXO.match(texto)
        if an:  # arquivo exportado junto (zip "incluir midia")
            nome = (an.group("a") or an.group("b")).strip()
            ext = nome.rsplit(".", 1)[-1].lower()
            tipo = TIPOS_MIDIA.get(ext, ("documento", None))[0]
            caminho_arq = os.path.join(pasta_midia, nome) if pasta_midia else None
            msgs.append({"local": local, "autor": autor.strip()[:80], "texto": an.group("leg").strip()[:4000],
                         "tipo": "outro" if nome.upper().startswith("STK-") else tipo,
                         "arquivo": caminho_arq if caminho_arq and os.path.exists(caminho_arq) else None})
            continue
        midia = bool(MIDIA.search(texto))
        msgs.append({"local": local, "autor": autor.strip()[:80],
                     "texto": "[midia nao exportada]" if midia else texto[:4000],
                     "tipo": "outro" if midia else "texto"})
    return msgs


def abrir_exportacao(arquivo):
    """Devolve (txt, pasta_das_midias). Um .zip e extraido em importar/historico/."""
    if not arquivo.lower().endswith(".zip"):
        return arquivo, None
    destino = os.path.join(DIR, "importar", "historico")
    with zipfile.ZipFile(arquivo) as z:
        nomes = [n for n in z.namelist() if not n.endswith("/")]
        txts = [n for n in nomes if n.lower().endswith(".txt")]
        if not txts:
            erro("O .zip nao tem a conversa (.txt). Exporte de novo pelo WhatsApp.")
        info(f"Extraindo {len(nomes)} arquivos do .zip...")
        z.extractall(destino)
    principal = max(txts, key=lambda n: z.getinfo(n).file_size)
    return os.path.join(destino, principal), os.path.dirname(os.path.join(destino, principal))


def normaliza_tag(t):
    dig = re.sub(r"\D", "", str(t or ""))
    if not dig:
        return None
    return (dig.lstrip("0") or "0").rjust(2, "0")[:12]


# ---------------------------------------------------------------- Supabase e Gemini
def pedir(url, corpo=None, cab=None, metodo=None, tempo=90):
    dados = json.dumps(corpo).encode() if corpo is not None else None
    req = urllib.request.Request(url, data=dados, method=metodo or ("POST" if dados else "GET"),
                                 headers={"Content-Type": "application/json", **(cab or {})})
    with urllib.request.urlopen(req, timeout=tempo) as r:
        txt = r.read().decode()
        return json.loads(txt) if txt.strip() else None


def sb(caminho, corpo=None, metodo=None, prefer=None):
    cab = {"apikey": SB_KEY}
    if prefer:
        cab["Prefer"] = prefer
    return pedir(f"{SB}/rest/v1/{caminho}", corpo, cab, metodo)


PROMPT = """Voce organiza o historico de um grupo de WhatsApp de motoristas e tecnicos de onibus de transporte de
funcionarios. No grupo eles relatam problemas nos CELULARES dos onibus (app BDV de viagem, carregamento, leitor de
passageiros, internet, suporte) e avisam quando resolveram. Abaixo estao TODAS as mensagens de UM dia (hora local).
Cada onibus tem um numero (tag), ex.: "carro 65", "65", "onibus 7".

Categorias: carregamento (nao carrega / carrega devagar / cabo), abrir_viagem (app nao abre ou nao fecha viagem),
contagem_passageiros (nao conta, leitor RFID), internet_chip (sem internet, chip), celular_defeito (tela, travando,
desligando, sumiu, quebrado), suporte (suporte solto/quebrado), som_musica (volume, musica), outro.

Devolva SO um JSON:
{"ocorrencias":[{"tag":"65","categoria":"carregamento","problema":"descricao curta (max 200 caracteres)",
  "urgencia":"baixa|media|alta","relatado_por":"nome de quem relatou","hora":"HH:MM","ultima_hora":"HH:MM",
  "reincidencias":0,"resolvida":false,"solucao":"","resolvido_por":"","hora_resolvido":"HH:MM","confianca":0.9}],
 "resolve_anteriores":[{"tag":"65","categoria":"carregamento","solucao":"...","resolvido_por":"...","hora":"HH:MM"}]}

Regras: uma ocorrencia por onibus + categoria no dia (repeticoes no mesmo dia contam em "reincidencias"). Ignore
conversa que nao e problema de onibus (bom dia, piadas, avisos gerais). Sem numero de onibus identificavel, use
"tag": null. "resolvida" so quando alguem disser claramente que resolveu/trocou/funcionou. "resolve_anteriores":
resolucoes, neste dia, de problemas da lista PENDENTES DE DIAS ANTERIORES. Nao invente nada que nao esteja nas mensagens.
"""


class SemCota(Exception):
    pass


def ler_midia(m, cache):
    """Transcreve audio / descreve foto e video com o Gemini (1 vez por arquivo)."""
    arq = m.get("arquivo")
    if not arq:
        return None
    chave = os.path.basename(arq)
    if chave in cache:
        return cache[chave]
    ext = arq.rsplit(".", 1)[-1].lower()
    if m["tipo"] not in ("audio", "video", "imagem") or ext not in TIPOS_MIDIA or os.path.getsize(arq) > MAX_MIDIA:
        return None
    pedido = ("Este arquivo veio de um grupo de WhatsApp sobre problemas nos celulares dos onibus (app BDV, "
              "carregamento, leitor de passageiros, internet, suporte). Em portugues, em ate 2 frases: "
              + ("transcreva o que a pessoa fala." if m["tipo"] == "audio" else
                 "descreva o que aparece que importa para o problema (numero do onibus, tela de erro, cabo, suporte...)."))
    corpo = {"contents": [{"parts": [{"text": pedido},
             {"inline_data": {"mime_type": TIPOS_MIDIA[ext][1], "data": base64.b64encode(open(arq, "rb").read()).decode()}}]}],
             "generationConfig": {"temperature": 0.1}}
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{GEM_MODEL}:generateContent"
    for tentativa in range(5):
        try:
            r = pedir(url, corpo, {"x-goog-api-key": GEM_KEY}, tempo=180)
            txt = r["candidates"][0]["content"]["parts"][0]["text"].strip()[:1000]
            cache[chave] = txt
            json.dump(cache, open(CACHE_MIDIA, "w"), ensure_ascii=False)
            time.sleep(4)
            return txt
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 503):
                espera = 60 * (tentativa + 1)
                aviso(f"Gemini ocupado/sem cota ({e.code}); esperando {espera} s...")
                time.sleep(espera)
                continue
            aviso(f"Nao consegui ler {chave} ({e.code}); segue sem ela.")
            return None
        except (KeyError, IndexError, ValueError, OSError):
            return None
    raise SemCota()  # cota do dia acabou: para sem marcar o dia, e continua dele na proxima vez


def gemini(dia, linhas, pendentes):
    texto = (PROMPT + f"\nDIA: {dia}\nPENDENTES DE DIAS ANTERIORES: {json.dumps(pendentes, ensure_ascii=False)}\n"
             + "MENSAGENS:\n" + "\n".join(linhas))
    corpo = {"contents": [{"parts": [{"text": texto}]}],
             "generationConfig": {"temperature": 0.1, "responseMimeType": "application/json"}}
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{GEM_MODEL}:generateContent"
    for tentativa in range(6):
        try:
            r = pedir(url, corpo, {"x-goog-api-key": GEM_KEY}, tempo=120)
            txt = r["candidates"][0]["content"]["parts"][0]["text"]
            return json.loads(re.sub(r"^```(json)?|```$", "", txt.strip()))
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 503):
                espera = 60 * (tentativa + 1)
                aviso(f"Gemini ocupado/sem cota ({e.code}); esperando {espera} s...")
                time.sleep(espera)
                continue
            raise
        except (KeyError, IndexError, ValueError):
            aviso("Resposta da IA veio estranha; tentando de novo...")
            time.sleep(5)
    return None


def inteiro(v):
    try:
        return max(0, int(v))
    except (TypeError, ValueError):
        return 0


def hora_ts(dia, hhmm, padrao):
    m = re.match(r"^(\d{1,2}):(\d{2})", str(hhmm or ""))
    if not m:
        return padrao
    return datetime(dia.year, dia.month, dia.day, int(m.group(1)) % 24, int(m.group(2)), tzinfo=BELEM).isoformat()


def main():
    dias = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 60
    pasta = os.path.join(DIR, "importar")
    exps = sorted((os.path.join(pasta, f) for f in os.listdir(pasta) if f.lower().endswith((".txt", ".zip"))),
                  key=os.path.getmtime)
    if not exps:
        erro(f"Nenhum .zip/.txt em {pasta}. Na Central: bloco WhatsApp > Importar historico.")
    arquivo = exps[-1]
    txt, pasta_midia = abrir_exportacao(arquivo)
    msgs = ler_conversa(txt, pasta_midia)
    if not msgs:
        erro("Nao reconheci nenhuma mensagem no arquivo. E a conversa exportada do WhatsApp (sem midia)?")
    ultimo = max(m["local"] for m in msgs).date()
    inicio = ultimo - timedelta(days=dias - 1)
    msgs = [m for m in msgs if m["local"].date() >= inicio]
    por_dia = {}
    for m in msgs:
        por_dia.setdefault(m["local"].date(), []).append(m)
    feitos = set(open(ESTADO).read().split()) if os.path.exists(ESTADO) else set()
    cache = json.load(open(CACHE_MIDIA)) if os.path.exists(CACHE_MIDIA) else {}
    n_midia = sum(1 for m in msgs if m.get("arquivo"))
    if n_midia:
        info(f"{n_midia} audios/fotos/videos no periodo: a IA le cada um antes (pode levar bem mais tempo).")
    ok(f"Arquivo: {os.path.basename(arquivo)} | {len(msgs)} mensagens de {inicio:%d/%m/%Y} a {ultimo:%d/%m/%Y} "
       f"| {len(por_dia)} dias com conversa ({len([d for d in por_dia if d.isoformat() in feitos])} ja importados)")

    try:
        sb("ocorrencias?select=id&limit=1")
    except urllib.error.HTTPError as e:
        erro(f"Supabase recusou ({e.code}). Rode sudo servidor whatsapp de novo para conferir a chave.")

    total_oc, total_res = 0, 0
    pendentes = []  # ocorrencias sem desfecho dos ultimos dias, para a IA achar a resolucao depois
    for dia in sorted(por_dia):
        lista = por_dia[dia]
        if dia.isoformat() in feitos:
            continue
        # 0) midias do dia: transcricao/descricao vira texto para a IA do dia
        for m in lista:
            m["transcricao"] = ler_midia(m, cache)
            if m["tipo"] in ("audio", "video", "imagem", "documento") and not m["transcricao"] and not m["texto"]:
                m["texto"] = f"[{m['tipo']} sem leitura]"
        # 1) mensagens brutas (nao duplica: id fixo pelo conteudo)
        brutas = []
        for m in lista:
            ts = m["local"].astimezone(timezone.utc).isoformat()
            base = m["texto"] + "|" + os.path.basename(m.get("arquivo") or "")
            mid = "retro:" + hashlib.sha1(f"{ts}|{m['autor']}|{base}".encode()).hexdigest()[:24]
            brutas.append({"msg_id": mid, "ts": ts, "grupo_jid": GRUPO, "autor_nome": m["autor"],
                           "tipo": m["tipo"], "texto": m["texto"] or None, "transcricao": m.get("transcricao"),
                           "acao_ia": "ignorar"})
        for i in range(0, len(brutas), 500):
            sb("whatsapp_msgs?on_conflict=msg_id", brutas[i:i + 500], prefer="resolution=ignore-duplicates,return=minimal")

        # 2) IA: ocorrencias do dia
        def linha_ia(m):
            m["texto"] = m["texto"].strip()
            t = m["texto"][:500]
            if m.get("transcricao"):
                t = (t + " " if t else "") + f"[{m['tipo']}: {m['transcricao'][:500]}]"
            return f"{m['local']:%H:%M} {m['autor']}: {t}"
        linhas = [linha_ia(m) for m in lista if m["texto"].strip() or m.get("transcricao")]  # figurinha sem texto fica de fora
        res = {"ocorrencias": [], "resolve_anteriores": []}
        for i in range(0, len(linhas), 400):  # dia muito movimentado vai em partes
            r = gemini(dia.strftime("%d/%m/%Y"), linhas[i:i + 400], pendentes[-40:])
            if r is None:
                aviso(f"{dia:%d/%m}: IA nao respondeu. Pare (Ctrl+C) e rode de novo amanha; continua deste dia.")
                return
            res["ocorrencias"] += r.get("ocorrencias") or []
            res["resolve_anteriores"] += r.get("resolve_anteriores") or []
        padrao = datetime(dia.year, dia.month, dia.day, 12, 0, tzinfo=BELEM).isoformat()

        # 3) resolucoes de dias anteriores
        for rv in res["resolve_anteriores"]:
            tag, cat = normaliza_tag(rv.get("tag")), rv.get("categoria")
            alvo = next((p for p in reversed(pendentes) if p["tag"] == tag and p["categoria"] == cat), None)
            if not alvo:
                continue
            sb(f"ocorrencias?id=eq.{alvo['id']}", {"status": "resolvida", "solucao": (rv.get("solucao") or "")[:1000] or None,
               "resolvido_por": (rv.get("resolvido_por") or "")[:80] or None,
               "resolvido_em": hora_ts(dia, rv.get("hora"), padrao)}, metodo="PATCH", prefer="return=minimal")
            pendentes.remove(alvo)
            total_res += 1

        # 4) ocorrencias novas do dia
        n = 0
        for o in res["ocorrencias"]:
            cat = o.get("categoria") if o.get("categoria") in CATEGORIAS else "outro"
            urg = o.get("urgencia") if o.get("urgencia") in ("baixa", "media", "alta") else "media"
            problema = (o.get("problema") or "").strip()[:300]
            if not problema:
                continue
            resolvida = o.get("resolvida") is True
            try:
                conf = max(0.0, min(1.0, float(o.get("confianca"))))
            except (TypeError, ValueError):
                conf = None
            linha = {"tag": normaliza_tag(o.get("tag")), "categoria": cat, "problema": problema, "urgencia": urg,
                     "status": "resolvida" if resolvida else "historico", "origem": "retroativo",
                     "relatado_por": (o.get("relatado_por") or "")[:80] or None,
                     "primeira_msg_em": hora_ts(dia, o.get("hora"), padrao),
                     "ultima_msg_em": hora_ts(dia, o.get("ultima_hora") or o.get("hora"), padrao),
                     "reincidencias": inteiro(o.get("reincidencias")),
                     "confianca": round(conf, 2) if conf is not None else None}
            if resolvida:
                linha.update({"solucao": (o.get("solucao") or "")[:1000] or None,
                              "resolvido_por": (o.get("resolvido_por") or "")[:80] or None,
                              "resolvido_em": hora_ts(dia, o.get("hora_resolvido"), linha["ultima_msg_em"])})
            criada = sb("ocorrencias", linha, prefer="return=representation")
            n += 1
            if not resolvida and criada and linha["tag"]:
                pendentes.append({"id": criada[0]["id"], "tag": linha["tag"], "categoria": cat,
                                  "dia": dia.strftime("%d/%m"), "problema": problema[:80]})
        total_oc += n
        feitos.add(dia.isoformat())
        with open(ESTADO, "a") as f:
            f.write(dia.isoformat() + "\n")
        ok(f"{dia:%d/%m/%Y}: {len(lista)} mensagens -> {n} ocorrencia(s)")
        time.sleep(4)  # respeita o limite por minuto da cota gratis

    ok(f"Fim: {total_oc} ocorrencias importadas, {total_res} resolvidas em dias seguintes.")
    print("Elas ficam com origem 'retroativo'. Sem desfecho no grupo = status 'historico' (nao aparece como aberta).")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        erro(f"{e.code} em {e.url}: {e.read().decode(errors='replace')[:300]}")
    except SemCota:
        aviso("A cota gratis do Gemini acabou por hoje. Rode de novo amanha: continua de onde parou.")
    except KeyboardInterrupt:
        aviso("Parado. Rode de novo para continuar de onde parou.")
