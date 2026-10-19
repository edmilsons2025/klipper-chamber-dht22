# Chamber DHT22 → Klipper / Mainsail

Temperatura e umidade da câmara (*chamber*) de uma impressora 3D com Klipper, medidas por um **DHT22 ligado num Orange Pi** e exibidas no **Mainsail** em um painel próprio, **Chamber**, com gráfico. Também há um firmware alternativo para [ESP8266/ESP32](#alternativa-esp8266-nodemcu-ou-esp32).

O sensor não fica na placa da impressora. Ele vai no Orange Pi, que já está ao lado da impressora, e o Klipper lê o valor pela rede como se o sensor fosse dele.

![Painel Chamber no Mainsail](docs/chamber-panel.png)

## Como funciona

```
DHT22 ──fio──► Orange Pi Zero 2W                         Ender 3 V3 KE (Klipper + Moonraker + Mainsail)
               ├─ kernel: driver dht11 (IIO)             ├─ módulo temperatura_remota.py
               │   /sys/bus/iio/devices/iio:device0      │   lê http://<pi>:8790/camara a cada 5 s
               └─ serviço "impressora" (Flask, :8790) ◄──┤   → temperature_sensor Chamber_Temp
                   GET /camara  → {temperatura, umidade} │   → temperature_sensor Chamber_Humidity
                                                         └─ Mainsail com o painel Chamber
```

1. **Orange Pi**: um *device tree overlay* liga o DHT22 ao driver `dht11` do kernel, que também lê o DHT22. O kernel faz a leitura com temporização precisa, sem bit-banging em Python.
2. **Serviço no Pi** (`orangepi/service`): lê o sensor a cada 10 s (com novas tentativas, porque o DHT às vezes falha uma leitura) e publica em `GET /camara`.
3. **Klipper** (`klipper/temperatura_remota.py`): um tipo de sensor novo para `temperature_sensor`. A requisição HTTP roda numa *thread* separada; o *reactor* do Klipper só lê o último valor, então rede lenta ou o Pi desligado nunca travam a impressora.
4. **Mainsail** (`mainsail/mainsail-chamber.patch`): painel **Chamber** com temperatura, umidade, mínimos e máximos, mais um gráfico com dois eixos (°C à esquerda, % à direita). Os sensores `Chamber_*` saem do painel Temperatures.

## Como a impressora lê o sensor (use qualquer sensor)

A impressora não sabe que existe um DHT22. Ela só faz, a cada 5 s, um `GET` HTTP numa URL e lê um número do JSON que volta. Qualquer coisa que responda nesse formato serve: outro sensor no Pi (BME280, SHT31, DS18B20, termopar), um ESP, um Raspberry, um Home Assistant...

**O que a impressora pede:**

```http
GET http://<ip-da-fonte>:<porta>/camara
```

**O que a fonte tem que responder** (status 200, corpo em JSON):

```json
{"ok": true, "temperatura": 23.4, "umidade": 48.1}
```

| Campo | Obrigatório | Regra |
|---|---|---|
| o campo escolhido em `valor:` | sim | número (ou texto com número, como `"23.4"`). Pode ter qualquer nome: `temperatura`, `umidade`, `pressao`, `co2`... |
| `ok` | não | se vier `false`, a leitura é ignorada. Sem o campo, vale como `true` |
| outros (`idade_s`, `erro`...) | não | ignorados pela impressora; servem para diagnóstico |

**Como cada valor vira um sensor no Klipper** (`camara_pi.cfg`):

```ini
[temperatura_remota]                  # carrega o módulo klippy/extras/temperatura_remota.py

[temperature_sensor Chamber_Temp]     # nome que aparece no Mainsail
sensor_type: temperatura_remota
url: http://192.168.1.60:8790/camara  # a URL da sua fonte
valor: temperatura                    # o campo do JSON que este sensor mostra
min_temp: -10
max_temp: 100
```

Para mostrar mais uma grandeza, crie outro `[temperature_sensor ...]` com a mesma `url` e outro `valor:`. O Klipper só conhece "temperatura", então umidade, pressão etc. aparecem como a temperatura desse sensor. É assim que entram no histórico do Moonraker e nos gráficos. O painel Chamber do Mainsail usa os sensores com nome `Chamber_*`, e o que tiver "humid" no nome é tratado como umidade (%).

**Comportamento quando a fonte falha:** a requisição tem 3 s de *timeout* e roda numa *thread* separada. Se a fonte cair, o Klipper continua funcionando e o sensor mostra o último valor válido. A impressão não é afetada.

**Fazer a sua fonte:** `exemplos/fonte_sensor.py` é um servidor pronto, só com a biblioteca padrão do Python. Edite a função `ler_sensor()`, que já traz exemplos para DHT22 via kernel, DS18B20 e BME280, e rode:

```bash
python3 exemplos/fonte_sensor.py --porta 8790
curl http://localhost:8790/camara
./install.sh klipper --impressora <ip-da-impressora> --url http://<ip-da-fonte>:8790/camara
```

Para testar uma fonte antes de instalar, rode na impressora: `wget -q -O - http://<ip-da-fonte>:8790/camara`.

## Hardware

| Item | Detalhe |
|---|---|
| Impressora | Creality Ender 3 V3 KE com root (Klipper, Moonraker e Mainsail via Creality Helper Script) |
| Computador do sensor | Orange Pi Zero 2W (Allwinner H618), Armbian, kernel 6.18 |
| Sensor | DHT22 / AM2302 em plaquinha de 3 pinos |
| Resistor | Pull-up de 4,7 kΩ a 10 kΩ entre **VCC e DATA** (a maioria das plaquinhas já tem; um a mais em paralelo não atrapalha) |

### Ligações (header de 40 pinos do Orange Pi Zero 2W)

| DHT22 | Pino do Pi | Sinal |
|---|---|---|
| VCC (+) | **1** | 3.3V |
| DATA (S / OUT) | **7** | PI13 |
| GND (−) | **9** | GND |

> ⚠️ O pino 6 **não é GND** nesse modelo: é o PH0, o TX do console serial. Confira também a ordem impressa na plaquinha do sensor; nem toda placa segue VCC-DATA-GND.

## Instalação

### Automática (`install.sh`)

O script faz os passos 1 a 4 abaixo. Rode no Orange Pi, dentro do clone do repositório:

```bash
sudo ./install.sh pi       --impressora <ip-da-impressora>   # overlay; reinicie e rode de novo para instalar o serviço
     ./install.sh klipper  --impressora <ip-da-impressora>   # módulo + camara_pi.cfg + [include] (SSH como root)
     ./install.sh mainsail --impressora <ip-da-impressora>   # opcional: precisa de Node.js 20+
     ./install.sh status   --impressora <ip-da-impressora>
```

O que ele garante:

- **backup antes de qualquer mudança**: `printer.cfg`, `camara_pi.cfg`, o módulo e o `armbianEnv.txt` ganham uma cópia `.bak-chamber-<data>`; o Mainsail original fica em `mainsail-original`;
- **não reinicia o Klipper durante uma impressão** (consulta o `print_stats` no Moonraker);
- **desfaz sozinho**: se o Klipper não voltar `ready` depois da instalação, restaura os arquivos anteriores e reinicia;
- **testa antes de mexer**: confere a placa (H616/H618, Zero 2W), lê o sensor e verifica se a impressora alcança `GET /camara` no Pi;
- **serviço com o mínimo de permissões**: no Docker, roda sem root, sem capabilities e com o sistema de arquivos só leitura. Sem Docker (`--runtime systemd`), usa um usuário próprio com as proteções do systemd. As variáveis da Alexa de um container `impressora` anterior são mantidas;
- `--dry-run` mostra tudo o que seria feito, sem mudar nada; o script não guarda senhas (o SSH pede a da impressora uma vez por execução);
- para voltar atrás: `./install.sh desinstalar-klipper` e `./install.sh restaurar-mainsail`.

O build do Mainsail pode ficar sem memória no Pi Zero 2W. Se acontecer, rode `./install.sh mainsail` num PC com Linux ou macOS.

### Manual

#### 1. Overlay no Orange Pi

```bash
sudo armbian-add-overlay orangepi/dht22-pi13.dts
sudo reboot
```

Depois do boot:

```bash
cat /sys/bus/iio/devices/iio:device0/in_temp_input              # 23300 = 23,3 °C
cat /sys/bus/iio/devices/iio:device0/in_humidityrelative_input  # 48000 = 48,0 %
```

**O detalhe que faz funcionar:** o overlay também define `input-debounce = <1 ...>` no controlador de GPIO. No padrão, o filtro de ruído das interrupções do Allwinner roda num relógio de 32 kHz (~31 µs). Isso engole os pulsos de 26–28 µs do DHT22, e o kernel registra `Only 22 signal edges detected` (uma leitura completa tem 84 bordas). Com o filtro no relógio de 24 MHz (1 µs), a leitura fecha.

#### 2. Serviço no Orange Pi

```bash
cd orangepi/service
docker build -t impressora .
docker run -d --name impressora --restart unless-stopped -p 8790:8790 \
  -e MOONRAKER_URL=http://<ip-da-impressora>:7125 -e TZ=America/Sao_Paulo impressora
curl http://localhost:8790/camara
# {"ok":true,"temperatura":21.1,"umidade":53.3,...}
```

O container lê `/sys/bus/iio` do host sem privilégios extras. O mesmo serviço também tem a ponte com a Alexa (ver abaixo); sem configurá-la, ela simplesmente não é usada.

#### 3. Klipper (na impressora)

```bash
scp klipper/temperatura_remota.py root@<impressora>:/usr/share/klipper/klippy/extras/
scp klipper/camara_pi.cfg        root@<impressora>:/usr/data/printer_data/config/
```

No `printer.cfg`, junto dos outros `[include]`:

```ini
[include camara_pi.cfg]
```

Os sensores (o parâmetro `valor` escolhe o campo do JSON que cada um lê; veja [Como a impressora lê o sensor](#como-a-impressora-lê-o-sensor-use-qualquer-sensor)):

```ini
[temperatura_remota]

[temperature_sensor Chamber_Temp]
sensor_type: temperatura_remota
url: http://<ip-do-pi>:8790/camara
valor: temperatura
min_temp: -10
max_temp: 100

[temperature_sensor Chamber_Humidity]
sensor_type: temperatura_remota
url: http://<ip-do-pi>:8790/camara
valor: umidade
min_temp: -10
max_temp: 100
```

> No `Chamber_Humidity`, o campo "temperature" do Klipper carrega a umidade em %. É assim que ela entra no histórico do Moonraker e no gráfico do Mainsail.

Reinicie o **serviço** do Klipper. O `RESTART` não recarrega módulos Python já importados:

```bash
/etc/init.d/S55klipper_service restart     # Creality OS; em outros sistemas: sudo systemctl restart klipper
```

#### 4. Mainsail com o painel Chamber

O patch foi feito sobre o **Mainsail v2.17.0**:

```bash
git clone --depth 1 --branch v2.17.0 https://github.com/mainsail-crew/mainsail.git
cd mainsail
git apply ../mainsail/mainsail-chamber.patch
CYPRESS_INSTALL_BINARY=0 npm ci
npx vite build
rm dist/config.json        # mantém o config.json que já está na impressora
```

Na impressora, guarde o original e troque:

```bash
cd /usr/data
cp -a mainsail mainsail-original
mkdir mainsail.new && tar xzf mainsail-chamber.tgz -C mainsail.new   # (o conteúdo de dist/)
cp mainsail/config.json mainsail.new/ && chmod -R a+rX mainsail.new
mv mainsail mainsail.old && mv mainsail.new mainsail
```

O que o patch muda:

- `src/components/panels/ChamberPanel.vue`: o painel novo;
- `src/plugins/chamber.ts`: identifica os sensores `temperature_sensor Chamber_*` (o de umidade tem "humid" no nome);
- Temperatures (lista e gráfico): deixa de mostrar os sensores da câmara;
- registro do painel no dashboard (`variables.ts`, `gui/getters.ts`, `Dashboard.vue`, ícone e texto em `en.json`). O painel só aparece se existir algum sensor `Chamber_*`.

> Atualizar o Mainsail pelo Moonraker volta para a versão oficial e o painel some. Para manter, aplique o patch na versão nova e gere o build de novo.

## Alternativa: ESP8266 (NodeMCU) ou ESP32

> ⚠️ **Não testado em hardware.** O firmware compila para `esp8266:esp8266:nodemcuv2` e `esp32:esp32:esp32` (ESP32 Dev Module), mas ainda não rodou numa placa de verdade. Se testar, abra uma *issue* contando como foi.

Não tem um Orange Pi (ou Raspberry) perto da impressora? Um NodeMCU ou ESP32 faz o mesmo papel. O Klipper e o Mainsail só precisam de um endereço que responda `GET /camara` com o mesmo JSON, e o firmware em `esp/chamber_dht22` faz exatamente isso:

```
DHT22 ──fio──► ESP8266 / ESP32 (Wi-Fi) ◄── HTTP ── Klipper (temperatura_remota.py) ──► Mainsail (painel Chamber)
```

```json
{"ok":true,"temperatura":23.4,"umidade":48.1,"idade_s":3,"erro":null}
```

O que muda em relação ao Pi:

- Com o ESP, você tem **só o sensor**. A ponte com a Alexa e o gráfico em PNG do serviço do Pi não existem nele.
- O ESP lê o DHT22 com a biblioteca da Adafruit, com temporização feita em software. Não precisa de overlay nem do ajuste de *debounce* que o Pi exigiu.
- Ele lê a cada 10 s. Se passar 2 min sem leitura válida, responde `"ok": false`, e o Klipper mantém o último valor até dar *timeout*.

### Ligações

| DHT22 | NodeMCU (ESP8266) | ESP32 DevKit |
|---|---|---|
| VCC (+) | **3V3** | **3V3** |
| DATA | **D2** (GPIO4) | **GPIO4** |
| GND (−) | **GND** | **GND** |

Use o mesmo pull-up de 4,7 kΩ a 10 kΩ entre VCC e DATA (a maioria das plaquinhas já tem um). Alimente o sensor com **3,3 V**: no ESP8266, 5 V no DATA pode danificar o pino. Evite pinos de *boot*: no NodeMCU, D3, D4 e D8; no ESP32, GPIO0, 2, 12 e 15.

### Gravação (Arduino IDE ou arduino-cli)

1. Instale o suporte à placa: ESP8266 (`https://arduino.esp8266.com/stable/package_esp8266com_index.json`) ou ESP32 (`https://espressif.github.io/arduino-esp32/package_esp32_index.json`).
2. Instale as bibliotecas **DHT sensor library** e **Adafruit Unified Sensor**.
3. Copie `esp/chamber_dht22/config.h.example` para `config.h` e preencha o Wi-Fi. O `config.h` fica fora do git.
4. Grave:

```bash
cd esp/chamber_dht22
# NodeMCU
arduino-cli compile --fqbn esp8266:esp8266:nodemcuv2 -u -p /dev/ttyUSB0 .
# ESP32
arduino-cli compile --fqbn esp32:esp32:esp32 -u -p /dev/ttyUSB0 .
```

O monitor serial (115200) mostra o IP e as leituras. Teste no navegador: `http://<ip-do-esp>/camara`.

### Klipper

O passo 3 da instalação fica igual. Só troque a `url` nos dois sensores:

```ini
url: http://<ip-do-esp>/camara
```

Ou deixe o instalador fazer isso: `./install.sh klipper --impressora <ip-da-impressora> --url http://<ip-do-esp>/camara`.

Prefira um **IP fixo**: reserve o IP no DHCP do roteador ou use `USE_STATIC_IP` no `config.h`. O firmware anuncia `chamber.local` por mDNS, mas o sistema da impressora geralmente não resolve nomes `.local`.

## Alexa (opcional, em andamento)

O serviço do Pi tem um endpoint de *custom skill* (`POST /alexa`, com verificação de assinatura da Amazon) para comandos como:

- "Alexa, pede pra minha impressora **aquecer a mesa em 65 graus**" / "aquecer o bico em 210" / "pré-aquecer PLA";
- "qual a temperatura do bico", "qual a umidade da câmara", "**quanto tempo falta**";
- "**parar a impressão**", que pede confirmação antes de cancelar.

O modelo de voz (pt-BR) está em `alexa/modelo_alexa.json`. O endpoint precisa estar acessível em HTTPS (aqui, por um túnel Cloudflare só no caminho `/alexa`). Ponto em aberto: a Amazon recusou o certificado Let's Encrypt de cadeia nova (YE2 → Root YE); a correção prevista é trocar a autoridade do certificado do Cloudflare para Google Trust Services.

## Licença

[MIT](LICENSE)
