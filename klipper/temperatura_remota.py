# Sensor remoto para o Klipper: lê um valor numérico de um JSON servido por HTTP.
#
# Feito para o DHT22 da câmara no Orange Pi, mas serve para qualquer sensor (BME280, SHT31, DS18B20,
# termopar, um ESP, outro computador...): basta algo na rede responder GET <url> com um JSON assim:
#
#   {"ok": true, "temperatura": 23.4, "umidade": 48.1}
#
#   - cada sensor do Klipper lê UM campo, escolhido por "valor" (qualquer nome: temperatura, umidade,
#     pressao, co2...); o campo precisa ser um número (ou texto com número, como "23.4");
#   - "ok" é opcional; se vier false, a leitura é ignorada e o último valor válido continua valendo;
#   - outros campos são ignorados; a resposta pode ter qualquer tamanho até 64 KB.
#
# Instalação: copiar para klippy/extras/ e, no printer.cfg (ou num arquivo incluído):
#   [temperatura_remota]
#
#   [temperature_sensor Chamber_Temp]
#   sensor_type: temperatura_remota
#   url: http://172.16.12.199:8790/camara
#   valor: temperatura        (o campo do JSON que este sensor mostra)
#   min_temp: -10
#   max_temp: 100
#
# O Klipper só conhece "temperatura": um sensor de outra grandeza (umidade em %, pressão...) aparece
# como a temperatura desse temperature_sensor. É assim que ele entra no histórico e nos gráficos.
#
# A leitura HTTP roda numa thread separada; o reactor do Klipper só lê o último valor,
# então rede lenta ou a fonte desligada nunca travam a impressora.
import json
import logging
import re
import threading
import time
import urllib.request

INTERVALO = 5.0
MAX_RESPOSTA = 64 * 1024


class TemperaturaRemota:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.name = config.get_name().split()[-1]
        self.url = config.get("url")
        if not re.match(r"^https?://", self.url):
            raise config.error("temperatura_remota: url deve começar com http:// ou https://")
        self.valor = config.get("valor", "temperatura")
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", self.valor):
            raise config.error("temperatura_remota: valor deve ser o nome de um campo do JSON (letras, números e _)")
        self.temp = 0.0
        self.min_temp = self.max_temp = 0.0
        self.callback = None
        self._ultimo_ok = 0.0
        self.timer = self.reactor.register_timer(self._amostra)
        self.printer.register_event_handler("klippy:connect", self._conectar)

        t = threading.Thread(target=self._buscar, daemon=True)
        t.start()

    def _conectar(self):
        self.reactor.update_timer(self.timer, self.reactor.NOW)

    def setup_minmax(self, min_temp, max_temp):
        self.min_temp, self.max_temp = min_temp, max_temp

    def setup_callback(self, cb):
        self.callback = cb

    def get_report_time_delta(self):
        return INTERVALO

    def _ler(self, dados):
        """Extrai o valor deste sensor do JSON recebido; None se a leitura não serve."""
        if not isinstance(dados, dict) or dados.get("ok", True) is False:
            return None
        v = dados.get(self.valor)
        if v is None or isinstance(v, bool):
            return None
        v = float(v)
        return v if v == v else None  # descarta NaN

    def _buscar(self):
        while True:
            try:
                with urllib.request.urlopen(self.url, timeout=3) as r:
                    v = self._ler(json.loads(r.read(MAX_RESPOSTA)))
                if v is not None:
                    self.temp = v
                    self._ultimo_ok = time.time()
            except Exception as e:
                logging.info("temperatura_remota %s: %s", self.name, e)
            time.sleep(INTERVALO)

    def _amostra(self, eventtime):
        if self.callback is not None:
            mcu = self.printer.lookup_object("mcu")
            self.callback(mcu.estimated_print_time(eventtime), self.temp)
        return eventtime + INTERVALO

    def get_status(self, eventtime):
        return {"temperature": round(self.temp, 1)}


def load_config(config):
    pheaters = config.get_printer().load_object(config, "heaters")
    pheaters.add_sensor_factory("temperatura_remota", TemperaturaRemota)
