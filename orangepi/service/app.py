"""Ponte entre a Ender 3 V3 KE (Klipper/Moonraker) e a Alexa, mais o sensor DHT22 da câmara.

Rotas:
- POST /alexa   endpoint da skill (assinatura e horário da requisição verificados pelo SDK da Amazon)
- GET  /camara  temperatura e umidade da câmara (lido pelo módulo do Klipper e pelo painel)
- GET  /status  resumo da impressora (diagnóstico)
"""
import glob
import json
import logging
import os
import threading
import time
import urllib.parse
import urllib.request

from flask import Flask, jsonify
from ask_sdk_core.skill_builder import SkillBuilder
from ask_sdk_core.utils import get_slot, is_intent_name, is_request_type
from ask_sdk_model import IntentConfirmationStatus
from ask_sdk_model.dialog import ConfirmIntentDirective
from flask_ask_sdk.skill_adapter import SkillAdapter

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("impressora")

MOONRAKER = os.environ.get("MOONRAKER_URL", "http://172.16.12.114:7125").rstrip("/")
SKILL_ID = os.environ.get("ALEXA_SKILL_ID", "")
NOTIFYME = os.environ.get("NOTIFYME_CODE", "")
MAX_BICO, MAX_MESA = 280, 100           # limites de segurança da KE
PRE = {"pla": (210, 65), "petg": (240, 80)}

# ------------------------------------------------------------------ DHT22 (driver dht11 do kernel, via IIO)
_camara = {"temperatura": None, "umidade": None, "ts": 0.0, "erro": None}


def _iio_dir():
    for d in glob.glob("/sys/bus/iio/devices/iio:device*"):
        if os.path.exists(f"{d}/in_humidityrelative_input"):
            return d
    return None


def _ler_dht():
    while True:
        d = _iio_dir()
        if not d:
            _camara["erro"] = "sensor não encontrado"
        else:
            for _ in range(4):  # o DHT às vezes falha uma leitura; tenta de novo
                try:
                    t = int(open(f"{d}/in_temp_input").read()) / 1000
                    h = int(open(f"{d}/in_humidityrelative_input").read()) / 1000
                    if -20 < t < 90 and 0 <= h <= 100:
                        _camara.update(temperatura=round(t, 1), umidade=round(h, 1), ts=time.time(), erro=None)
                        break
                except Exception as e:
                    _camara["erro"] = str(e)[:80]
                    time.sleep(2.5)
        time.sleep(10)


threading.Thread(target=_ler_dht, daemon=True).start()


# ------------------------------------------------------------------ histórico e gráfico da câmara
import collections
import io

HIST = collections.deque(maxlen=6 * 60 * 4)   # uma amostra a cada 15 s, 6 horas
JANELA = 3 * 3600                             # o gráfico mostra as últimas 3 horas


def _historico():
    while True:
        if camara_ok():
            HIST.append((time.time(), _camara["temperatura"], _camara["umidade"]))
        time.sleep(15)


threading.Thread(target=_historico, daemon=True).start()


def grafico_png(w=900, h=320):
    from PIL import Image, ImageDraw, ImageFont
    bg, grade, txt, cu, ct = (18, 18, 18), (48, 48, 48), (170, 170, 170), (38, 166, 154), (171, 71, 188)
    im = Image.new("RGB", (w, h), bg)
    d = ImageDraw.Draw(im)
    try:
        f = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 13)
        fb = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 15)
    except Exception:
        f = fb = ImageFont.load_default()
    x0, x1, y0, y1 = 48, w - 48, 40, h - 30
    agora = time.time()
    pts = [p for p in HIST if p[0] >= agora - JANELA]
    # escalas: umidade 0–100 % à esquerda; temperatura à direita, ajustada aos dados
    temps = [p[1] for p in pts] or [20.0]
    tmin, tmax = min(temps) - 2, max(temps) + 2
    if tmax - tmin < 6:
        meio = (tmax + tmin) / 2
        tmin, tmax = meio - 3, meio + 3
    for i in range(6):
        y = y0 + (y1 - y0) * i / 5
        d.line([(x0, y), (x1, y)], fill=grade)
        d.text((6, y - 7), f"{100 - i * 20}%", fill=cu, font=f)
        d.text((x1 + 6, y - 7), f"{tmax - (tmax - tmin) * i / 5:.1f}°", fill=ct, font=f)
    for i in range(7):
        x = x0 + (x1 - x0) * i / 6
        d.line([(x, y0), (x, y1)], fill=grade)
        t = time.localtime(agora - JANELA + JANELA * i / 6)
        d.text((x - 16, y1 + 8), time.strftime("%H:%M", t), fill=txt, font=f)

    def xy(p, val, lo, hi):
        x = x0 + (x1 - x0) * (p[0] - (agora - JANELA)) / JANELA
        y = y1 - (y1 - y0) * (val - lo) / (hi - lo)
        return (x, max(y0, min(y1, y)))

    if len(pts) > 1:
        d.line([xy(p, p[2], 0, 100) for p in pts], fill=cu, width=2)
        d.line([xy(p, p[1], tmin, tmax) for p in pts], fill=ct, width=2)
    if camara_ok():
        cab = f"Humidity {_camara['umidade']:.1f}%    Temp {_camara['temperatura']:.1f}°C"
    else:
        cab = "Chamber sensor offline"
    d.text((x0, 12), cab, fill=(230, 230, 230), font=fb)
    d.text((x1 - 70, 14), "last 3 h", fill=txt, font=f)
    buf = io.BytesIO()
    im.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def camara_ok():
    return _camara["temperatura"] is not None and time.time() - _camara["ts"] < 120


# ------------------------------------------------------------------ Moonraker
def mr_get(path):
    with urllib.request.urlopen(MOONRAKER + path, timeout=5) as r:
        return json.loads(r.read())["result"]


def mr_post(path):
    req = urllib.request.Request(MOONRAKER + path, data=b"", method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def gcode(script):
    return mr_post("/printer/gcode/script?script=" + urllib.parse.quote(script))


def estado():
    q = mr_get("/printer/objects/query?extruder&heater_bed&print_stats&virtual_sdcard")["status"]
    ps, vs = q.get("print_stats", {}), q.get("virtual_sdcard", {})
    e = {
        "bico": round(q["extruder"]["temperature"]), "bico_alvo": round(q["extruder"]["target"]),
        "mesa": round(q["heater_bed"]["temperature"]), "mesa_alvo": round(q["heater_bed"]["target"]),
        "estado": ps.get("state", "standby"), "arquivo": ps.get("filename") or "",
        "duracao": ps.get("print_duration") or 0, "progresso": vs.get("progress") or 0,
    }
    e["restante"] = None
    if e["estado"] in ("printing", "paused"):
        est = None
        try:
            est = mr_get("/server/files/metadata?filename=" + urllib.parse.quote(e["arquivo"])).get("estimated_time")
        except Exception:
            pass
        p = e["progresso"]
        if p > 0.1:
            e["restante"] = e["duracao"] / p - e["duracao"]
        elif est:
            e["restante"] = max(0, est - e["duracao"])
    return e


def nome_arquivo(a):
    a = os.path.splitext(os.path.basename(a or ""))[0]
    return a.replace("_", " ").replace("-", " ")[:60] or "sem nome"


def duracao_fala(seg):
    seg = int(seg or 0)
    h, m = seg // 3600, (seg % 3600) // 60
    if h and m:
        return f"{h} {'hora' if h == 1 else 'horas'} e {m} minutos"
    if h:
        return f"{h} {'hora' if h == 1 else 'horas'}"
    return f"{max(m, 1)} {'minuto' if m <= 1 else 'minutos'}"


ESTADOS = {"standby": "parada", "printing": "imprimindo", "paused": "pausada", "complete": "com a impressão concluída",
           "cancelled": "com a impressão cancelada", "error": "com erro"}

# ------------------------------------------------------------------ Alexa
sb = SkillBuilder()


def falar(hi, texto, fim=True):
    r = hi.response_builder.speak(texto)
    if not fim:
        r = r.ask("O que mais?")
    return r.set_should_end_session(fim).response


def slot_num(hi, nome):
    s = get_slot(hi, nome)
    try:
        return int(float(s.value)) if s and s.value else None
    except Exception:
        return None


def slot_id(hi, nome):
    """Valor canônico de um slot customizado (resolve sinônimos: 'extrusor' -> bico)."""
    s = get_slot(hi, nome)
    if not s:
        return None
    try:
        for r in s.resolutions.resolutions_per_authority:
            if r.values:
                return r.values[0].value.name.lower()
    except Exception:
        pass
    return (s.value or "").lower() or None


def sem_conexao(hi):
    return falar(hi, "Não consegui falar com a impressora. Ela está ligada?")


def bloqueio_imprimindo(hi, e):
    if e["estado"] == "printing":
        return falar(hi, "A impressora está imprimindo agora. Não vou mexer nas temperaturas durante a impressão.")
    return None


@sb.request_handler(can_handle_func=is_request_type("LaunchRequest"))
def abrir(hi):
    return falar(hi, "Impressora pronta. Você pode pedir a temperatura, o tempo restante ou mandar aquecer.", fim=False)


@sb.request_handler(can_handle_func=is_intent_name("AquecerIntent"))
def aquecer(hi):
    parte = slot_id(hi, "parte") or "mesa"
    graus = slot_num(hi, "graus")
    if graus is None:
        return falar(hi, f"Quantos graus para {'o bico' if parte == 'bico' else 'a mesa'}?", fim=False)
    try:
        e = estado()
    except Exception:
        return sem_conexao(hi)
    b = bloqueio_imprimindo(hi, e)
    if b:
        return b
    if parte == "bico":
        if not 0 <= graus <= MAX_BICO:
            return falar(hi, f"O bico vai no máximo até {MAX_BICO} graus.")
        gcode(f"M104 S{graus}")
        return falar(hi, f"Aquecendo o bico para {graus} graus. Agora ele está em {e['bico']}.")
    if not 0 <= graus <= MAX_MESA:
        return falar(hi, f"A mesa vai no máximo até {MAX_MESA} graus.")
    gcode(f"M140 S{graus}")
    return falar(hi, f"Aquecendo a mesa para {graus} graus. Agora ela está em {e['mesa']}.")


@sb.request_handler(can_handle_func=is_intent_name("PreAquecerIntent"))
def pre_aquecer(hi):
    mat = slot_id(hi, "material") or "pla"
    bico, mesa = PRE.get(mat, PRE["pla"])
    try:
        e = estado()
    except Exception:
        return sem_conexao(hi)
    b = bloqueio_imprimindo(hi, e)
    if b:
        return b
    gcode(f"M140 S{mesa}\nM104 S{bico}")
    return falar(hi, f"Pré-aquecendo para {mat.upper()}: bico em {bico} e mesa em {mesa} graus.")


@sb.request_handler(can_handle_func=is_intent_name("EsfriarIntent"))
def esfriar(hi):
    try:
        e = estado()
    except Exception:
        return sem_conexao(hi)
    if e["estado"] == "printing":
        return falar(hi, "A impressora está imprimindo. Para desligar o aquecimento, peça para parar a impressão.")
    gcode("M104 S0\nM140 S0")
    return falar(hi, "Aquecimento desligado. O bico está em {} e a mesa em {} graus.".format(e["bico"], e["mesa"]))


@sb.request_handler(can_handle_func=is_intent_name("TemperaturaIntent"))
def temperatura(hi):
    parte = slot_id(hi, "local")
    if parte == "camara":
        if not camara_ok():
            return falar(hi, "Não estou conseguindo ler o sensor da câmara.")
        return falar(hi, f"A câmara está com {str(_camara['temperatura']).replace('.', ',')} graus e "
                         f"{round(_camara['umidade'])} por cento de umidade.")
    try:
        e = estado()
    except Exception:
        return sem_conexao(hi)

    def frase(nome, atual, alvo, art):
        if alvo:
            return f"{art} {nome} está em {atual} graus, {'aquecendo para' if atual < alvo - 2 else 'mantendo'} {alvo}."
        return f"{art} {nome} está em {atual} graus, sem aquecimento."

    if parte == "bico":
        return falar(hi, frase("bico", e["bico"], e["bico_alvo"], "O"))
    if parte == "mesa":
        return falar(hi, frase("mesa", e["mesa"], e["mesa_alvo"], "A"))
    txt = frase("bico", e["bico"], e["bico_alvo"], "O") + " " + frase("mesa", e["mesa"], e["mesa_alvo"], "A")
    if camara_ok():
        txt += f" A câmara está com {round(_camara['temperatura'])} graus."
    return falar(hi, txt)


@sb.request_handler(can_handle_func=is_intent_name("UmidadeIntent"))
def umidade(hi):
    if not camara_ok():
        return falar(hi, "Não estou conseguindo ler o sensor da câmara.")
    return falar(hi, f"A umidade da câmara está em {round(_camara['umidade'])} por cento, "
                     f"com {str(_camara['temperatura']).replace('.', ',')} graus.")


@sb.request_handler(can_handle_func=is_intent_name("TempoRestanteIntent"))
def tempo_restante(hi):
    try:
        e = estado()
    except Exception:
        return sem_conexao(hi)
    if e["estado"] not in ("printing", "paused"):
        return falar(hi, f"Não tem nenhuma impressão em andamento. A impressora está {ESTADOS.get(e['estado'], e['estado'])}.")
    txt = f"A impressão de {nome_arquivo(e['arquivo'])} está em {round(e['progresso'] * 100)} por cento"
    if e["restante"] is not None:
        txt += f". Faltam mais ou menos {duracao_fala(e['restante'])}"
    if e["estado"] == "paused":
        txt += ". Ela está pausada"
    return falar(hi, txt + ".")


@sb.request_handler(can_handle_func=is_intent_name("StatusIntent"))
def status(hi):
    try:
        e = estado()
    except Exception:
        return sem_conexao(hi)
    txt = f"A impressora está {ESTADOS.get(e['estado'], e['estado'])}."
    if e["estado"] in ("printing", "paused"):
        txt += f" Arquivo {nome_arquivo(e['arquivo'])}, {round(e['progresso'] * 100)} por cento."
    txt += f" Bico em {e['bico']} e mesa em {e['mesa']} graus."
    if camara_ok():
        txt += f" Câmara com {round(_camara['temperatura'])} graus e {round(_camara['umidade'])} por cento de umidade."
    return falar(hi, txt)


@sb.request_handler(can_handle_func=is_intent_name("PausarIntent"))
def pausar(hi):
    try:
        if estado()["estado"] != "printing":
            return falar(hi, "Não tem impressão rodando para pausar.")
        mr_post("/printer/print/pause")
    except Exception:
        return sem_conexao(hi)
    return falar(hi, "Impressão pausada.")


@sb.request_handler(can_handle_func=is_intent_name("RetomarIntent"))
def retomar(hi):
    try:
        if estado()["estado"] != "paused":
            return falar(hi, "A impressão não está pausada.")
        mr_post("/printer/print/resume")
    except Exception:
        return sem_conexao(hi)
    return falar(hi, "Retomando a impressão.")


@sb.request_handler(can_handle_func=is_intent_name("CancelarImpressaoIntent"))
def cancelar(hi):
    intent = hi.request_envelope.request.intent
    try:
        e = estado()
    except Exception:
        return sem_conexao(hi)
    if e["estado"] not in ("printing", "paused"):
        return falar(hi, "Não tem nenhuma impressão em andamento.")
    conf = intent.confirmation_status
    if conf == IntentConfirmationStatus.CONFIRMED:
        mr_post("/printer/print/cancel")
        return falar(hi, "Impressão cancelada.")
    if conf == IntentConfirmationStatus.DENIED:
        return falar(hi, "Tudo bem, a impressão continua.")
    return (hi.response_builder
            .speak(f"Você quer mesmo parar a impressão de {nome_arquivo(e['arquivo'])}, que está em "
                   f"{round(e['progresso'] * 100)} por cento? Não dá para desfazer.")
            .ask("Confirma que quer parar a impressão?")
            .add_directive(ConfirmIntentDirective(updated_intent=intent))
            .response)


@sb.request_handler(can_handle_func=is_intent_name("AMAZON.HelpIntent"))
def ajuda(hi):
    return falar(hi, "Você pode dizer: aquecer a mesa em 65 graus, aquecer o bico em 210, pré-aquecer PLA, "
                     "qual a temperatura do bico, quanto tempo falta, pausar ou parar a impressão.", fim=False)


@sb.request_handler(can_handle_func=lambda hi: is_intent_name("AMAZON.CancelIntent")(hi)
                    or is_intent_name("AMAZON.StopIntent")(hi) or is_intent_name("AMAZON.NavigateHomeIntent")(hi))
def sair(hi):
    return falar(hi, "Até mais.")


@sb.request_handler(can_handle_func=is_intent_name("AMAZON.FallbackIntent"))
def fallback(hi):
    return falar(hi, "Não entendi. Diga ajuda para ouvir os comandos.", fim=False)


@sb.request_handler(can_handle_func=is_request_type("SessionEndedRequest"))
def fim_sessao(hi):
    return hi.response_builder.response


@sb.exception_handler(can_handle_func=lambda hi, ex: True)
def erro(hi, ex):
    log.exception("erro na skill: %s", ex)
    return falar(hi, "Deu um problema ao falar com a impressora.")


# ------------------------------------------------------------------ avisos de fim/erro (Notify Me)
def _avisar(texto):
    if not NOTIFYME:
        return
    try:
        req = urllib.request.Request("https://api.notifymyecho.com/v1/NotifyMe", method="POST",
                                     data=json.dumps({"notification": texto, "accessCode": NOTIFYME}).encode(),
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=10).read()
    except Exception as e:
        log.warning("Notify Me falhou: %s", e)


def _vigiar():
    anterior = None
    while True:
        try:
            e = estado()
            atual = e["estado"]
            if anterior == "printing" and atual == "complete":
                _avisar(f"A impressão de {nome_arquivo(e['arquivo'])} terminou.")
            elif anterior in ("printing", "paused") and atual == "error":
                _avisar(f"A impressão de {nome_arquivo(e['arquivo'])} parou com erro.")
            anterior = atual
        except Exception:
            pass  # impressora desligada
        time.sleep(15)


threading.Thread(target=_vigiar, daemon=True).start()

# ------------------------------------------------------------------ HTTP
app = Flask(__name__)
SkillAdapter(skill=sb.create(), skill_id=SKILL_ID or "nao-configurado", app=app).register(app=app, route="/alexa")


@app.before_request
def _log_req():
    from flask import request
    if request.path.startswith("/camara"):
        return
    log.info("REQ %s %s cf-ip=%s assinatura=%s", request.method, request.path,
             request.headers.get("Cf-Connecting-Ip", "-"), "sim" if request.headers.get("Signature-256") else "nao")


@app.after_request
def _log_resp(resp):
    from flask import request
    if request.path == "/alexa":
        log.info("RESP /alexa %s %s", resp.status_code, resp.get_data(as_text=True)[:200])
    return resp


@app.get("/camara")
def rota_camara():
    return jsonify({**_camara, "ok": camara_ok()})


_graf_cache = {"png": b"", "ts": 0.0}


@app.get("/camara/grafico.png")
def rota_grafico():
    from flask import Response
    # o Mainsail pede a imagem 1 vez por segundo; redesenha no máximo a cada 15 s
    if time.time() - _graf_cache["ts"] > 15:
        _graf_cache.update(png=grafico_png(), ts=time.time())
    return Response(_graf_cache["png"], mimetype="image/png", headers={"Cache-Control": "no-store"})


@app.get("/status")
def rota_status():
    try:
        e = estado()
    except Exception as ex:
        e = {"erro": str(ex)[:120]}
    return jsonify({"impressora": e, "camara": _camara})


if __name__ == "__main__":
    from waitress import serve
    serve(app, host="0.0.0.0", port=8790, threads=4)
