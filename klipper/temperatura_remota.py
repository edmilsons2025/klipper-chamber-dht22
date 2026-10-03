# Sensor de temperatura remoto para o Klipper (lê a câmara medida pelo DHT22 do Orange Pi).
#
# Instalação: copiar para klippy/extras/ e, no printer.cfg:
#   [temperatura_remota]
#
#   [temperature_sensor Camara_Temp]
#   sensor_type: temperatura_remota
#   url: http://172.16.12.199:8790/camara
#   valor: temperatura        (ou umidade, para um segundo sensor com a umidade em %)
#   min_temp: -10
#   max_temp: 100
#
# A leitura HTTP roda numa thread separada; o reactor do Klipper só lê o último valor,
# então rede lenta ou o Pi desligado nunca travam a impressora.
import json
import logging
import threading
import time
import urllib.request

INTERVALO = 5.0


class TemperaturaRemota:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.name = config.get_name().split()[-1]
        self.url = config.get("url")
        self.valor = config.getchoice("valor", {"temperatura": "temperatura", "umidade": "umidade"}, "temperatura")
        self.temp = 0.0
        self.umidade = None
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

    def _buscar(self):
        while True:
            try:
                with urllib.request.urlopen(self.url, timeout=3) as r:
                    d = json.loads(r.read())
                if d.get("ok") and d.get(self.valor) is not None:
                    self.temp = float(d[self.valor])
                    self.umidade = d.get("umidade")
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
