#!/usr/bin/env python3
# Importa o HISTORICO do grupo de ocorrencias a partir da conversa exportada do WhatsApp (.txt, "sem midia").
# Uso na TV Box:  sudo servidor retroativo [dias]     (padrao: 60 dias; le o .txt mais novo de /opt/servidor/importar)
#
# Para cada dia: manda as mensagens do dia para o Gemini (1 chamada por dia, cabe na cota gratis), que devolve as
# ocorrencias daquele dia; grava no Supabase com origem = 'retroativo'. O que foi resolvido no proprio grupo vira
# 'resolvida'; o resto vira 'historico' (aconteceu, mas o grupo nao registrou o desfecho) e nao entra como aberta.
# As mensagens brutas vao para whatsapp_msgs (id "retro:..."), para consulta. Pode rodar de novo: continua de onde parou.
import hashlib, json, os, re, sys, time, unicodedata, urllib.error, urllib.request
from datetime import datetime, timedelta, timezone

DIR = os.environ.get("DIR", "/opt/servidor")
SB = os.environ["SUPABASE_URL"].rstrip("/")
SB_KEY = os.environ["SUPABASE_KEY"]
GEM_KEY = os.environ["GEMINI_KEY"]
GEM_MODEL = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash-lite")
GRUPO = (os.environ.get("GRUPOS", "") or "retroativo").split(",")[0]
BELEM = timezone(timedelta(hours=-3))
ESTADO = os.path.join(DIR, "importar", ".retroativo-feito")
CATEGORIAS = ["carregamento", "abrir_viagem", "contagem_passageiros", "internet_chip", "celular_defeito",
              "suporte", "som_musica", "outro"]


def ok(m): print(f"\033[32m[OK]\033[0m {m}", flush=True)
def info(m): print(f"\033[36m[..]\033[0m {m}", flush=True)
def aviso(m): print(f"\033[33m[!]\033[0m {m}", flush=True)
def erro(m): print(f"\033[31m[ERRO]\033[0m {m}", flush=True); sys.exit(1)


# ---------------------------------------------------------------- leitura do .txt exportado (Android e iPhone)
RE_ANDROID = re.compile(r"^(\d{1,2})/(\d{1,2})/(\d{2,4}),? (\d{1,2}):(\d{2})(?::(\d{2}))? [-–] (.*)$")
RE_IPHONE = re.compile(r"^\[(\d{1,2})/(\d{1,2})/(\d{2,4}),? (\d{1,2}):(\d{2})(?::(\d{2}))?\] (.*)$")
MIDIA = re.compile(r"m[ií]dia oculta|arquivo de m[ií]dia oculto|omitid[oa]|ocultad[oa]|\(arquivo anexado\)|"
                   r"<attached:|media omitted|imagem ocultada|figurinha omitida", re.I)


def ler_conversa(caminho):
    msgs = []
    for linha in open(caminho, encoding="utf-8-sig", errors="replace"):
        linha = linha.replace("‎", "").replace(" ", " ").rstrip("\r\n")
        m = RE_IPHONE.match(linha) or RE_ANDROID.match(linha)
        if not m:
            if msgs and linha.strip():
                msgs[-1]["texto"] = (msgs[-1]["texto"] + "\n" + linha.strip())[:4000]  # continuacao da mensagem
            continue
        d, mes, ano, hh, mi, ss, resto = m.groups()
        ano = int(ano) + (2000 if len(ano) == 2 else 0)
        try:
            local = datetime(ano, int(mes), int(d), int(hh), int(mi), int(ss or 0), tzinfo=BELEM)
        except ValueError:
            continue
        if ": " not in resto:
            continue  # aviso do sistema (entrou, saiu, mudou o nome do grupo...)
        autor, texto = resto.split(": ", 1)
        midia = bool(MIDIA.search(texto))
        msgs.append({"local": local, "autor": autor.strip()[:80],
                     "texto": "[midia nao exportada]" if midia else texto.strip()[:4000],
                     "tipo": "outro" if midia else "texto"})
    return msgs


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
    txts = sorted((os.path.join(pasta, f) for f in os.listdir(pasta) if f.lower().endswith(".txt")),
                  key=os.path.getmtime)
    if not txts:
        erro(f"Nenhum .txt em {pasta}. Na Central: bloco WhatsApp > Importar historico (.txt).")
    arquivo = txts[-1]
    msgs = ler_conversa(arquivo)
    if not msgs:
        erro("Nao reconheci nenhuma mensagem no arquivo. E a conversa exportada do WhatsApp (sem midia)?")
    ultimo = max(m["local"] for m in msgs).date()
    inicio = ultimo - timedelta(days=dias - 1)
    msgs = [m for m in msgs if m["local"].date() >= inicio]
    por_dia = {}
    for m in msgs:
        por_dia.setdefault(m["local"].date(), []).append(m)
    feitos = set(open(ESTADO).read().split()) if os.path.exists(ESTADO) else set()
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
        # 1) mensagens brutas (nao duplica: id fixo pelo conteudo)
        brutas = []
        for m in lista:
            ts = m["local"].astimezone(timezone.utc).isoformat()
            mid = "retro:" + hashlib.sha1(f"{ts}|{m['autor']}|{m['texto']}".encode()).hexdigest()[:24]
            brutas.append({"msg_id": mid, "ts": ts, "grupo_jid": GRUPO, "autor_nome": m["autor"],
                           "tipo": m["tipo"], "texto": m["texto"], "acao_ia": "ignorar"})
        for i in range(0, len(brutas), 500):
            sb("whatsapp_msgs?on_conflict=msg_id", brutas[i:i + 500], prefer="resolution=ignore-duplicates,return=minimal")

        # 2) IA: ocorrencias do dia
        linhas = [f"{m['local']:%H:%M} {m['autor']}: {m['texto'][:500]}" for m in lista]
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
    except KeyboardInterrupt:
        aviso("Parado. Rode de novo para continuar de onde parou.")
