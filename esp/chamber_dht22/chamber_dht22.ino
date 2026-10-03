/*
 * chamber_dht22 — firmware ESP8266 (NodeMCU) / ESP32 para o klipper-chamber-dht22.
 *
 * Substitui o Orange Pi como fonte do sensor: lê um DHT22 e expõe
 *   GET /camara  ->  {"ok":true,"temperatura":23.4,"umidade":48.1,"idade_s":3,"erro":null}
 * no mesmo formato que o módulo Klipper temperatura_remota.py espera.
 *
 * NÃO TESTADO EM HARDWARE — apenas compilado para esp8266:nodemcuv2 e esp32:esp32 (ESP32 Dev Module).
 *
 * Bibliotecas: "DHT sensor library" + "Adafruit Unified Sensor" (Adafruit).
 */
#include "config.h"
#include <DHT.h>

#if defined(ESP8266)
  #include <ESP8266WiFi.h>
  #include <ESP8266WebServer.h>
  #include <ESP8266mDNS.h>
  ESP8266WebServer server(80);
#elif defined(ESP32)
  #include <WiFi.h>
  #include <WebServer.h>
  #include <ESPmDNS.h>
  WebServer server(80);
#else
  #error "Placa não suportada: use ESP8266 ou ESP32"
#endif

static const unsigned long INTERVALO_LEITURA_MS = 10000;   // DHT22 aceita no máximo ~1 leitura a cada 2 s
static const unsigned long VALIDADE_MS          = 120000;  // após isso sem leitura boa, ok=false
static const unsigned long RECONEXAO_MS         = 10000;

DHT dht(DHT_PIN, DHT22);

float ultimaTemp = NAN;
float ultimaUmid = NAN;
unsigned long ultimaLeituraOk = 0;
bool algumaLeituraOk = false;
const char *ultimoErro = "sem leitura ainda";

unsigned long proximaLeitura = 0;
unsigned long proximaReconexao = 0;

void lerSensor() {
  float h = dht.readHumidity();
  float t = dht.readTemperature();

  if (isnan(t) || isnan(h)) {
    ultimoErro = "falha na leitura do DHT22";
    return;
  }
  if (t <= -20 || t >= 90 || h < 0 || h > 100) {
    ultimoErro = "leitura fora da faixa";
    return;
  }
  ultimaTemp = t;
  ultimaUmid = h;
  ultimaLeituraOk = millis();
  algumaLeituraOk = true;
  ultimoErro = nullptr;
}

bool dadosValidos() {
  return algumaLeituraOk && (millis() - ultimaLeituraOk) < VALIDADE_MS;
}

void handleCamara() {
  bool ok = dadosValidos();
  String json = "{\"ok\":";
  json += ok ? "true" : "false";
  json += ",\"temperatura\":";
  json += ok ? String(ultimaTemp, 1) : "null";
  json += ",\"umidade\":";
  json += ok ? String(ultimaUmid, 1) : "null";
  json += ",\"idade_s\":";
  json += algumaLeituraOk ? String((millis() - ultimaLeituraOk) / 1000) : "null";
  json += ",\"erro\":";
  if (ok || ultimoErro == nullptr) {
    json += "null";
  } else {
    json += "\"";
    json += ultimoErro;
    json += "\"";
  }
  json += "}";

  server.sendHeader("Cache-Control", "no-store");
  server.send(200, "application/json", json);
}

void handleRaiz() {
  server.send(200, "text/plain", "chamber_dht22 - use /camara\n");
}

void conectarWifi() {
  WiFi.mode(WIFI_STA);
#if defined(ESP8266)
  WiFi.hostname(HOSTNAME);
#else
  WiFi.setHostname(HOSTNAME);
#endif
#if USE_STATIC_IP
  WiFi.config(IPAddress(STATIC_IP), IPAddress(STATIC_GW), IPAddress(STATIC_MASK));
#endif
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  Serial.print("Conectando ao Wi-Fi");
  unsigned long inicio = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - inicio < 20000) {
    delay(500);
    Serial.print(".");
  }
  Serial.println();
  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("IP: ");
    Serial.println(WiFi.localIP());
  } else {
    Serial.println("Sem Wi-Fi por enquanto; tentando de novo no loop.");
  }
}

void setup() {
  Serial.begin(115200);
  delay(200);
  dht.begin();
  conectarWifi();

  if (MDNS.begin(HOSTNAME)) {
    MDNS.addService("http", "tcp", 80);
  }

  server.on("/", handleRaiz);
  server.on("/camara", handleCamara);
  server.begin();

  proximaLeitura = millis() + 2000;  // DHT22 precisa de ~1-2 s após ligar
}

void loop() {
  unsigned long agora = millis();

  if (WiFi.status() != WL_CONNECTED && (long)(agora - proximaReconexao) >= 0) {
    proximaReconexao = agora + RECONEXAO_MS;
    WiFi.disconnect();
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  }

  if ((long)(agora - proximaLeitura) >= 0) {
    proximaLeitura = agora + INTERVALO_LEITURA_MS;
    lerSensor();
    if (ultimoErro) {
      Serial.println(ultimoErro);
    } else {
      Serial.printf("%.1f C  %.1f %%\n", ultimaTemp, ultimaUmid);
    }
  }

  server.handleClient();
#if defined(ESP8266)
  MDNS.update();
#endif
}
