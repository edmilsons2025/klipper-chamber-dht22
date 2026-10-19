"""Fonte mínima de sensor para o Klipper (módulo temperatura_remota.py). Só usa a biblioteca padrão.

Serve GET /camara com o JSON que a impressora espera:

    {"ok": true, "temperatura": 23.4, "umidade": 48.1, "idade_s": 2, "erro": null}

Para usar outro sensor, troque só a função ler_sensor(). Ela devolve um dicionário com os campos
numéricos que você quiser. Cada temperature_sensor no Klipper escolhe um campo com "valor:".

    python3 fonte_sensor.py                 # porta 8790
    python3 fonte_sensor.py --porta 8080
    curl http://localhost:8790/camara
"""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

INTERVALO = 10       # segundos entre leituras
VALIDADE = 120       # depois disso sem leitura boa, responde "ok": false


def ler_sensor():
    """Lê o sensor e devolve {"campo": número, ...}. Lance uma exceção se a leitura falhar.

    Exemplos (descomente o que servir):

    # DHT22/DHT11 pelo driver do kernel (é o que o serviço do Orange Pi faz):
    #   d = "/sys/bus/iio/devices/iio:device0"
    #   return {"temperatura": int(open(f"{d}/in_temp_input").read()) / 1000,
    #           "umidade": int(open(f"{d}/in_humidityrelative_input").read()) / 1000}

    # DS18B20 (1-Wire, overlay w1-gpio):
    #   import glob
    #   linha = open(glob.glob("/sys/bus/w1/devices/28-*/w1_slave")[0]).read()
    #   return {"temperatura": int(linha.rsplit("t=", 1)[1]) / 1000}

    # BME280 por I2C (pip install adafruit-circuitpython-bme280):
    #   import board, adafruit_bme280.basic as bme
    #   s = bme.Adafruit_BME280_I2C(board.I2C())
    #   return {"temperatura": s.temperature, "umidade": s.humidity, "pressao": s.pressure}
    """
    raise NotImplementedError("edite ler_sensor() em fonte_sensor.py para o seu sensor")


_estado = {"dados": {}, "ts": 0.0, "erro": None}


def _laco():
    while True:
        try:
            dados = {k: round(float(v), 2) for k, v in ler_sensor().items()}
            _estado.update(dados=dados, ts=time.time(), erro=None)
        except Exception as e:
            _estado["erro"] = str(e)[:120]
        time.sleep(INTERVALO)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] != "/camara":
            self.send_error(404)
            return
        idade = time.time() - _estado["ts"] if _estado["ts"] else None
        corpo = json.dumps({
            "ok": idade is not None and idade < VALIDADE,
            **_estado["dados"],
            "idade_s": None if idade is None else int(idade),
            "erro": _estado["erro"],
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corpo)))
        self.end_headers()
        self.wfile.write(corpo)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--porta", type=int, default=8790)
    ap.add_argument("--host", default="0.0.0.0")
    a = ap.parse_args()
    threading.Thread(target=_laco, daemon=True).start()
    print(f"servindo http://{a.host}:{a.porta}/camara")
    ThreadingHTTPServer((a.host, a.porta), Handler).serve_forever()
