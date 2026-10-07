#!/usr/bin/env bash
# Instalador do Chamber DHT22 (Orange Pi Zero 2W + Ender 3 V3 KE com Klipper/Moonraker/Mainsail).
#
# Roda no Orange Pi, dentro do clone deste repositório. A parte da impressora é feita por SSH.
#
#   sudo ./install.sh pi       --impressora 192.168.1.50   # overlay + serviço no Pi
#        ./install.sh klipper  --impressora 192.168.1.50   # módulo + sensores no Klipper
#        ./install.sh mainsail --impressora 192.168.1.50   # painel Chamber (precisa de Node.js)
#        ./install.sh status   --impressora 192.168.1.50
#        ./install.sh desinstalar-klipper | restaurar-mainsail --impressora 192.168.1.50
#
# Opções: --pi-ip <ip> (padrão: detectado)  --usuario-ssh root  --porta 8790  --runtime docker|systemd
#         --tz America/Sao_Paulo  --mainsail-versao v2.17.0  --dry-run  -y/--sim (não pergunta)
#
# Segurança:
#   - nada é sobrescrito sem backup com data/hora (printer.cfg, armbianEnv.txt, Mainsail...);
#   - o Klipper não é reiniciado com impressão em andamento ou pausada;
#   - se o Klipper não voltar "ready" depois da mudança, o printer.cfg e os arquivos anteriores são restaurados;
#   - --dry-run mostra o que seria feito sem mudar nada; nenhuma senha é pedida pelo script nem guardada
#     (o SSH pede a senha da impressora, uma vez por execução).
set -Eeuo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

IMPRESSORA=""
PI_IP=""
SSH_USER="root"
PORTA=8790
MR_PORTA=7125
TZ_CONTAINER="${TZ:-America/Sao_Paulo}"
RUNTIME=""                 # docker | systemd (padrão: docker se existir)
MAINSAIL_VERSAO="v2.17.0"  # versão sobre a qual o patch foi feito
SIM=0
DRY_RUN=0

# ------------------------------------------------------------------ saída
if [[ -t 1 ]]; then C_AZ=$'\e[34m' C_VD=$'\e[32m' C_AM=$'\e[33m' C_VM=$'\e[31m' C_0=$'\e[0m'; else C_AZ="" C_VD="" C_AM="" C_VM="" C_0=""; fi
info()  { echo "${C_AZ}==>${C_0} $*"; }
ok()    { echo "${C_VD} ✔${C_0} $*"; }
aviso() { echo "${C_AM} !${C_0} $*" >&2; }
erro()  { echo "${C_VM} ✘ $*${C_0}" >&2; exit 1; }

confirmar() {
    [[ $SIM == 1 ]] && return 0
    local r
    read -r -p "    $1 [s/N] " r </dev/tty || return 1
    [[ $r =~ ^[sSyY] ]]
}

# executa um comando que muda alguma coisa (respeita --dry-run)
run() {
    if [[ $DRY_RUN == 1 ]]; then echo "    [dry-run] $*"; return 0; fi
    "$@"
}

uso() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

TMP="$(mktemp -d)"
SSH_CTL="$TMP/ssh-ctl"
limpar() {
    [[ -S $SSH_CTL ]] && ssh -o ControlPath="$SSH_CTL" -O exit _ 2>/dev/null || true
    rm -rf "$TMP"
}
trap limpar EXIT

precisa() { for c in "$@"; do command -v "$c" >/dev/null || erro "comando '$c' não encontrado. Instale-o e rode de novo."; done; }

# endereço só com letras, números, ponto e hífen: entra em comandos remotos e no .cfg
endereco_valido() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }

precisa_impressora() {
    [[ -n $IMPRESSORA ]] || erro "informe o IP da impressora: --impressora <ip>"
    endereco_valido "$IMPRESSORA" || erro "endereço da impressora inválido: $IMPRESSORA"
}

# ------------------------------------------------------------------ Moonraker
mr_json() {  # mr_json <caminho> <expressão python sobre r = json["result"]>
    curl -fsS --max-time 5 "http://$IMPRESSORA:$MR_PORTA$1" 2>/dev/null |
        python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(eval(sys.argv[1]))' "$2" 2>/dev/null
}

estado_impressao() { mr_json "/printer/objects/query?print_stats" 'r["status"]["print_stats"]["state"]'; }

garantir_impressora_parada() {
    local e
    if e="$(estado_impressao)"; then
        case "$e" in
            printing|paused) erro "a impressora está '$e'. Rode de novo quando a impressão terminar (o Klipper precisa ser reiniciado)." ;;
            *) ok "impressora sem impressão em andamento ($e)" ;;
        esac
    else
        aviso "não consegui consultar o Moonraker em http://$IMPRESSORA:$MR_PORTA para ver se há impressão em andamento."
        confirmar "Tem certeza de que a impressora NÃO está imprimindo?" || erro "cancelado."
    fi
}

esperar_klipper() {  # devolve 0 quando "ready"; mostra a mensagem de erro do Klipper se falhar
    local i st
    sleep 3
    for ((i = 0; i < 45; i++)); do
        st="$(mr_json /printer/info 'r["state"]' || true)"
        case "$st" in
            ready) return 0 ;;
            error|shutdown)
                aviso "Klipper em '$st': $(mr_json /printer/info 'r["state_message"]' || true)"
                return 1 ;;
        esac
        sleep 2
    done
    aviso "o Klipper não ficou pronto em 90 s (último estado: ${st:-sem resposta})."
    return 1
}

# ------------------------------------------------------------------ SSH (uma conexão reaproveitada: a senha é pedida uma vez)
SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=$SSH_CTL" -o ControlPersist=300
          -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

rsh_ro() { ssh "${SSH_OPTS[@]}" "$SSH_USER@$IMPRESSORA" "$1"; }          # leitura: roda mesmo em --dry-run
rsh()    { run ssh "${SSH_OPTS[@]}" "$SSH_USER@$IMPRESSORA" "$1"; }       # mudança

# envia um arquivo local; grava num temporário e renomeia, para nunca deixar um arquivo pela metade
rput() {
    if [[ $DRY_RUN == 1 ]]; then echo "    [dry-run] enviar $1 -> $IMPRESSORA:$2"; return 0; fi
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$IMPRESSORA" "cat > '$2.tmp-chamber' && mv '$2.tmp-chamber' '$2'" <"$1"
}

conectar_impressora() {
    precisa ssh curl python3
    info "Conectando em $SSH_USER@$IMPRESSORA por SSH (no Creality OS a senha padrão de root é creality_2023)"
    rsh_ro true || erro "não consegui entrar por SSH em $SSH_USER@$IMPRESSORA."
    ok "SSH ok"
}

detectar_klipper() {
    KL_EXTRAS="$(rsh_ro 'for d in /usr/share/klipper/klippy/extras "$HOME/klipper/klippy/extras"; do [ -d "$d" ] && { echo "$d"; break; }; done' || true)"
    KL_CFG="$(rsh_ro 'for d in /usr/data/printer_data/config "$HOME/printer_data/config"; do [ -f "$d/printer.cfg" ] && { echo "$d"; break; }; done' || true)"
    KL_RESTART="$(rsh_ro 'if [ -x /etc/init.d/S55klipper_service ]; then echo "/etc/init.d/S55klipper_service restart";
        elif command -v systemctl >/dev/null; then [ "$(id -u)" = 0 ] && echo "systemctl restart klipper" || echo "sudo -n systemctl restart klipper"; fi' || true)"
    [[ -n $KL_EXTRAS ]] || erro "não achei a pasta klippy/extras do Klipper na impressora."
    [[ -n $KL_CFG ]] || erro "não achei o printer.cfg na impressora."
    [[ -n $KL_RESTART ]] || erro "não sei como reiniciar o serviço do Klipper nessa impressora."
    ok "Klipper: $KL_EXTRAS"
    ok "config:  $KL_CFG/printer.cfg"
}

detectar_pi_ip() {
    if [[ -z $PI_IP ]]; then
        PI_IP="$(ip -4 route get "$(getent ahostsv4 "$IMPRESSORA" | awk 'NR==1{print $1}')" 2>/dev/null |
                 sed -n 's/.* src \([0-9.]*\).*/\1/p' || true)"
        [[ -n $PI_IP ]] || erro "não consegui descobrir o IP do Orange Pi. Use --pi-ip <ip>."
    fi
    endereco_valido "$PI_IP" || erro "IP do Pi inválido: $PI_IP"
}

# ================================================================== Orange Pi
pi_checar_placa() {
    local compat model
    compat="$(tr '\0' ' ' </proc/device-tree/compatible 2>/dev/null || true)"
    model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
    [[ $compat == *sun50i-h616* || $compat == *sun50i-h618* ]] ||
        erro "esta placa não é Allwinner H616/H618 ($model). O overlay é só para o Orange Pi Zero 2W."
    if [[ $model != *[Zz]ero*2[Ww]* ]]; then
        aviso "modelo '$model': o overlay usa o PI13 (pino 7) do Orange Pi Zero 2W. Em outra placa esse pino pode ser outra coisa."
        confirmar "Continuar mesmo assim?" || erro "cancelado."
    fi
    ok "placa: $model"
}

sensor_iio() {
    local d
    for d in /sys/bus/iio/devices/iio:device*; do
        [[ -e $d/in_humidityrelative_input ]] && { echo "$d"; return 0; }
    done
    return 1
}

pi_ler_sensor() {  # o DHT falha leituras de vez em quando: tenta algumas vezes
    local d t h i
    d="$(sensor_iio)" || return 1
    for ((i = 0; i < 6; i++)); do
        if t="$(cat "$d/in_temp_input" 2>/dev/null)" && h="$(cat "$d/in_humidityrelative_input" 2>/dev/null)"; then
            ok "sensor: $(awk -v t="$t" -v h="$h" 'BEGIN{printf "%.1f °C, %.1f %%", t/1000, h/1000}')"
            return 0
        fi
        sleep 2.5
    done
    return 1
}

pi_overlay() {
    local env=/boot/armbianEnv.txt
    if sensor_iio >/dev/null; then
        ok "overlay já ativo (driver dht11 carregado)"
        return 0
    fi
    if [[ -f /boot/overlay-user/dht22-pi13.dtbo ]] && grep -qE '^user_overlays=.*\bdht22-pi13\b' "$env" 2>/dev/null; then
        aviso "o overlay já está instalado, mas o sensor não apareceu. Falta reiniciar o Pi?"
        if confirmar "Reiniciar agora? Depois rode o mesmo comando de novo."; then run reboot; fi
        exit 0
    fi
    precisa armbian-add-overlay
    command -v dtc >/dev/null || erro "falta o 'dtc' (sudo apt install device-tree-compiler)."
    info "Instalando o overlay do DHT22 (PI13, pino 7)"
    run cp -a "$env" "$env.bak-chamber-$STAMP"
    ok "backup: $env.bak-chamber-$STAMP"
    run armbian-add-overlay "$REPO/orangepi/dht22-pi13.dts"
    ok "overlay instalado. Ele só vale depois de reiniciar."
    if confirmar "Reiniciar o Pi agora? Depois do boot rode o mesmo comando de novo para continuar."; then
        run reboot
    fi
    exit 0
}

pi_env_alexa() {  # preserva a configuração da Alexa de um container 'impressora' anterior
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' impressora 2>/dev/null |
        grep -E '^(ALEXA_SKILL_ID|NOTIFYME_CODE)=' || true
}

pi_servico_docker() {
    local envf="$TMP/impressora.env"
    info "Construindo a imagem Docker 'impressora'"
    run docker build -q -t impressora "$REPO/orangepi/service" >/dev/null
    ( umask 077
      { echo "MOONRAKER_URL=http://$IMPRESSORA:$MR_PORTA"; echo "TZ=$TZ_CONTAINER"; pi_env_alexa; } >"$envf" )
    if docker container inspect impressora >/dev/null 2>&1; then
        aviso "já existe um container 'impressora'. Ele será trocado (ALEXA_SKILL_ID e NOTIFYME_CODE são mantidos)."
        confirmar "Trocar o container?" || erro "cancelado."
        run docker rm -f impressora >/dev/null
    fi
    # sem root, sem capabilities, sistema de arquivos só leitura: o serviço só lê /sys e abre a porta
    run docker run -d --name impressora --restart unless-stopped -p "$PORTA:8790" --env-file "$envf" \
        --user 65534:65534 --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp \
        impressora >/dev/null
    ok "container 'impressora' rodando"
}

pi_servico_systemd() {
    local dest=/opt/chamber-dht22 unit=/etc/systemd/system/chamber-dht22.service envf=/etc/chamber-dht22.env
    precisa python3 systemctl
    if ! python3 -c 'import venv, ensurepip' 2>/dev/null; then
        confirmar "Falta o python3-venv. Instalar com apt?" || erro "cancelado."
        run apt-get install -y python3-venv
    fi
    [[ $PORTA == 8790 ]] || aviso "no modo systemd o serviço usa sempre a porta 8790."
    info "Instalando o serviço em $dest (usuário sem privilégios 'chamber')"
    id chamber >/dev/null 2>&1 || run useradd --system --no-create-home --shell /usr/sbin/nologin chamber
    run install -d -m 755 "$dest"
    run install -m 644 "$REPO/orangepi/service/app.py" "$REPO/orangepi/service/requirements.txt" "$dest/"
    [[ -x $dest/venv/bin/python ]] || run python3 -m venv "$dest/venv"
    run "$dest/venv/bin/pip" install -q -r "$dest/requirements.txt"
    if [[ -f $envf ]]; then
        run cp -a "$envf" "$envf.bak-chamber-$STAMP"
        run sed -i "s|^MOONRAKER_URL=.*|MOONRAKER_URL=http://$IMPRESSORA:$MR_PORTA|" "$envf"
    elif [[ $DRY_RUN == 0 ]]; then
        ( umask 027; printf 'MOONRAKER_URL=http://%s:%s\nTZ=%s\n#ALEXA_SKILL_ID=\n#NOTIFYME_CODE=\n' \
            "$IMPRESSORA" "$MR_PORTA" "$TZ_CONTAINER" >"$envf" )
        chgrp chamber "$envf"
    fi
    [[ $DRY_RUN == 1 ]] && { echo "    [dry-run] criar $unit e iniciar chamber-dht22"; return 0; }
    cat >"$unit" <<EOF
[Unit]
Description=Chamber DHT22 (GET /camara na porta 8790)
After=network-online.target
Wants=network-online.target

[Service]
User=chamber
Group=chamber
EnvironmentFile=$envf
WorkingDirectory=$dest
ExecStart=$dest/venv/bin/python app.py
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=
LockPersonality=yes
MemoryDenyWriteExecute=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now chamber-dht22
    systemctl restart chamber-dht22
    ok "serviço systemd 'chamber-dht22' rodando"
}

pi_testar_servico() {
    local i r
    [[ $DRY_RUN == 1 ]] && return 0
    info "Testando http://localhost:$PORTA/camara"
    for ((i = 0; i < 20; i++)); do
        if r="$(curl -fsS --max-time 3 "http://localhost:$PORTA/camara" 2>/dev/null)" && [[ $r == *'"ok":true'* ]]; then
            ok "serviço respondendo: $r"
            return 0
        fi
        sleep 3
    done
    aviso "o serviço não respondeu com uma leitura válida em 60 s. Última resposta: ${r:-nenhuma}"
    return 1
}

cmd_pi() {
    [[ $EUID == 0 || $DRY_RUN == 1 ]] || erro "a etapa do Pi precisa de root: sudo $0 pi ..."
    precisa_impressora
    precisa curl awk
    pi_checar_placa
    pi_overlay
    if ! pi_ler_sensor; then
        aviso "o driver carregou, mas o sensor não respondeu. Confira a ligação (VCC no pino 1, DATA no 7, GND no 9)."
        dmesg 2>/dev/null | grep -i dht11 | tail -n 3 >&2 || true
        confirmar "Instalar o serviço mesmo assim?" || erro "cancelado."
    fi
    if [[ -z $RUNTIME ]]; then
        if command -v docker >/dev/null && docker info >/dev/null 2>&1; then RUNTIME=docker; else RUNTIME=systemd; fi
    fi
    case "$RUNTIME" in
        docker) precisa docker; pi_servico_docker ;;
        systemd) pi_servico_systemd ;;
        *) erro "--runtime deve ser docker ou systemd" ;;
    esac
    pi_testar_servico || true
    echo
    ok "Pi pronto. Próximo passo (sem sudo): $0 klipper --impressora $IMPRESSORA"
}

# ================================================================== Klipper (na impressora)
gerar_cfg() {
    cat <<EOF
# Chamber: DHT22 ligado no Orange Pi ($PI_IP), lido pela rede.
# Gerado por install.sh em $STAMP. Módulo: $KL_EXTRAS/temperatura_remota.py
[temperatura_remota]

[temperature_sensor Chamber_Temp]
sensor_type: temperatura_remota
url: http://$PI_IP:$PORTA/camara
valor: temperatura
min_temp: -10
max_temp: 100

[temperature_sensor Chamber_Humidity]
sensor_type: temperatura_remota
url: http://$PI_IP:$PORTA/camara
valor: umidade
min_temp: -10
max_temp: 100
EOF
}

RE_INCLUDE='^[[:space:]]*\[include[[:space:]]+camara_pi\.cfg[[:space:]]*\]'

# põe o [include] depois do último [include] existente (ou no topo), nunca dentro do bloco do SAVE_CONFIG
adicionar_include() {
    local n
    n="$(grep -nE '^[[:space:]]*\[include[[:space:]]' "$1" | tail -n 1 | cut -d: -f1 || true)"
    if [[ -n $n ]]; then
        awk -v n="$n" '{print} NR==n{print "[include camara_pi.cfg]"}' "$1"
    else
        awk 'NR==1{print "[include camara_pi.cfg]"; print ""} {print}' "$1"
    fi
}

klipper_restaurar() {  # desfaz a instalação a partir dos backups desta execução
    aviso "Restaurando a configuração anterior"
    rsh "cd '$KL_CFG' && cp -a 'printer.cfg.bak-chamber-$STAMP' printer.cfg
         if [ -f 'camara_pi.cfg.bak-chamber-$STAMP' ]; then mv 'camara_pi.cfg.bak-chamber-$STAMP' camara_pi.cfg; else rm -f camara_pi.cfg; fi
         cd '$KL_EXTRAS' && if [ -f 'temperatura_remota.py.bak-chamber-$STAMP' ]; then mv 'temperatura_remota.py.bak-chamber-$STAMP' temperatura_remota.py; else rm -f temperatura_remota.py; fi
         $KL_RESTART" || true
    if esperar_klipper; then ok "configuração anterior restaurada, Klipper pronto"; else aviso "confira o Klipper no Mainsail"; fi
}

cmd_klipper() {
    precisa_impressora
    detectar_pi_ip
    conectar_impressora
    detectar_klipper

    info "Testando o sensor a partir da impressora (http://$PI_IP:$PORTA/camara)"
    local r
    r="$(rsh_ro "wget -q -O - -T 5 'http://$PI_IP:$PORTA/camara' 2>/dev/null || curl -fsS -m 5 'http://$PI_IP:$PORTA/camara'" || true)"
    if [[ $r == *'"ok":true'* ]]; then
        ok "a impressora alcança o Pi: $r"
    else
        aviso "a impressora não recebeu uma leitura válida do Pi (${r:-sem resposta}). O serviço do Pi está rodando?"
        confirmar "Instalar no Klipper mesmo assim?" || erro "cancelado."
    fi

    rsh_ro "cat '$KL_CFG/printer.cfg'" >"$TMP/printer.cfg" || erro "não consegui ler o printer.cfg."
    [[ -s $TMP/printer.cfg ]] || erro "não consegui ler o printer.cfg."
    if grep -qE '^[[:space:]]*\[(temperatura_remota|temperature_sensor[[:space:]]+Chamber_(Temp|Humidity))[[:space:]]*\]' "$TMP/printer.cfg"; then
        erro "o printer.cfg já tem seções [temperatura_remota]/Chamber_* escritas à mão. Remova-as (o script usa camara_pi.cfg) e rode de novo."
    fi
    gerar_cfg >"$TMP/camara_pi.cfg"
    local novo_include=0
    if grep -qE "$RE_INCLUDE" "$TMP/printer.cfg"; then
        ok "printer.cfg já tem [include camara_pi.cfg]"
    else
        adicionar_include "$TMP/printer.cfg" >"$TMP/printer.cfg.novo"
        novo_include=1
        echo "    mudança no printer.cfg:"
        diff -u "$TMP/printer.cfg" "$TMP/printer.cfg.novo" | sed -n '3,$p' | sed 's/^/      /' || true
    fi

    echo
    info "Vou instalar na impressora:"
    echo "    $KL_EXTRAS/temperatura_remota.py"
    echo "    $KL_CFG/camara_pi.cfg  (sensores lendo http://$PI_IP:$PORTA/camara)"
    [[ $novo_include == 1 ]] && echo "    [include camara_pi.cfg] no printer.cfg"
    echo "    e reiniciar o serviço do Klipper ($KL_RESTART)"
    garantir_impressora_parada
    confirmar "Continuar?" || erro "cancelado."

    info "Backups (sufixo .bak-chamber-$STAMP)"
    rsh "cd '$KL_CFG' && cp -a printer.cfg 'printer.cfg.bak-chamber-$STAMP'
         [ ! -f camara_pi.cfg ] || cp -a camara_pi.cfg 'camara_pi.cfg.bak-chamber-$STAMP'
         cd '$KL_EXTRAS' && { [ ! -f temperatura_remota.py ] || cp -a temperatura_remota.py 'temperatura_remota.py.bak-chamber-$STAMP'; }"

    info "Enviando arquivos"
    rput "$REPO/klipper/temperatura_remota.py" "$KL_EXTRAS/temperatura_remota.py"
    rput "$TMP/camara_pi.cfg" "$KL_CFG/camara_pi.cfg"
    [[ $novo_include == 1 ]] && rput "$TMP/printer.cfg.novo" "$KL_CFG/printer.cfg"
    rsh "rm -rf '$KL_EXTRAS/__pycache__/temperatura_remota'*"

    info "Reiniciando o Klipper (o RESTART por G-code não recarrega módulos Python)"
    rsh "$KL_RESTART >/dev/null 2>&1"
    [[ $DRY_RUN == 1 ]] && return 0
    if ! esperar_klipper; then
        klipper_restaurar
        erro "a instalação foi desfeita. Os arquivos .bak-chamber-$STAMP continuam na impressora."
    fi
    ok "Klipper pronto"
    sleep 6
    local t h
    t="$(mr_json '/printer/objects/query?temperature_sensor%20Chamber_Temp' 'r["status"]["temperature_sensor Chamber_Temp"]["temperature"]' || true)"
    h="$(mr_json '/printer/objects/query?temperature_sensor%20Chamber_Humidity' 'r["status"]["temperature_sensor Chamber_Humidity"]["temperature"]' || true)"
    ok "Chamber_Temp = ${t:-?} °C, Chamber_Humidity = ${h:-?} %"
    echo
    ok "Klipper pronto. Para o painel no Mainsail: $0 mainsail --impressora $IMPRESSORA"
}

cmd_desinstalar_klipper() {
    precisa_impressora
    conectar_impressora
    detectar_klipper
    rsh_ro "cat '$KL_CFG/printer.cfg'" >"$TMP/printer.cfg" || erro "não consegui ler o printer.cfg."
    [[ -s $TMP/printer.cfg ]] || erro "não consegui ler o printer.cfg."
    grep -vE "$RE_INCLUDE" "$TMP/printer.cfg" >"$TMP/printer.cfg.novo" || true
    info "Vou remover camara_pi.cfg, temperatura_remota.py e o [include] do printer.cfg (com backup), e reiniciar o Klipper"
    garantir_impressora_parada
    confirmar "Continuar?" || erro "cancelado."
    rsh "cd '$KL_CFG' && cp -a printer.cfg 'printer.cfg.bak-chamber-$STAMP'
         [ ! -f camara_pi.cfg ] || mv camara_pi.cfg 'camara_pi.cfg.bak-chamber-$STAMP'
         cd '$KL_EXTRAS' && { [ ! -f temperatura_remota.py ] || mv temperatura_remota.py 'temperatura_remota.py.bak-chamber-$STAMP'; }"
    rput "$TMP/printer.cfg.novo" "$KL_CFG/printer.cfg"
    rsh "$KL_RESTART >/dev/null 2>&1"
    [[ $DRY_RUN == 1 ]] && return 0
    esperar_klipper && ok "removido; Klipper pronto" || aviso "confira o Klipper no Mainsail (backups .bak-chamber-$STAMP na impressora)"
}

# ================================================================== Mainsail
detectar_mainsail() {
    MS_DIR="$(rsh_ro 'for d in /usr/data/mainsail "$HOME/mainsail"; do [ -f "$d/index.html" ] && { echo "$d"; break; }; done' || true)"
    [[ -n $MS_DIR ]] || erro "não achei o Mainsail na impressora (/usr/data/mainsail ou ~/mainsail)."
    ok "Mainsail: $MS_DIR"
}

cmd_mainsail() {
    precisa_impressora
    precisa git node npm tar
    local major src="$REPO/.build/mainsail"
    major="$(node -p 'process.versions.node.split(".")[0]')"
    (( major >= 20 )) || erro "o build do Mainsail precisa do Node.js 20 ou mais novo (encontrado: $(node -v))."
    conectar_impressora
    detectar_mainsail

    info "Preparando o Mainsail $MAINSAIL_VERSAO com o patch do painel Chamber"
    if [[ ! -d $src/.git ]]; then
        run git clone -q --depth 1 --branch "$MAINSAIL_VERSAO" https://github.com/mainsail-crew/mainsail.git "$src"
    else
        run git -C "$src" checkout -q -- . && run git -C "$src" clean -qfd   # volta ao original, mantém node_modules
    fi
    if [[ $DRY_RUN == 0 ]]; then
        git -C "$src" apply --check "$REPO/mainsail/mainsail-chamber.patch" ||
            erro "o patch não aplica no Mainsail $MAINSAIL_VERSAO."
    fi
    run git -C "$src" apply "$REPO/mainsail/mainsail-chamber.patch"
    info "Build (alguns minutos; num Pi Zero 2W pode faltar memória, aí rode esta etapa num PC)"
    if [[ $DRY_RUN == 1 ]]; then
        echo "    [dry-run] npm ci && npx vite build em $src"
    else
        ( cd "$src" && export CYPRESS_INSTALL_BINARY=0 NPM_CONFIG_UPDATE_NOTIFIER=false && npm ci --no-audit --no-fund --loglevel=error && npx vite build --logLevel warn )
    fi
    run rm -f "$src/dist/config.json"   # mantém o config.json que já está na impressora
    [[ $DRY_RUN == 1 || -f $src/dist/index.html ]] || erro "o build não gerou dist/index.html."
    ok "build pronto"

    info "Vou trocar $MS_DIR pela versão com o painel. Backups: ${MS_DIR}-original (só na primeira vez) e ${MS_DIR}.old"
    confirmar "Continuar?" || erro "cancelado."
    rsh "rm -rf '$MS_DIR.new' && mkdir '$MS_DIR.new'"
    if [[ $DRY_RUN == 1 ]]; then
        echo "    [dry-run] enviar dist/ -> $IMPRESSORA:$MS_DIR.new"
    else
        tar -C "$src/dist" -cf - . | ssh "${SSH_OPTS[@]}" "$SSH_USER@$IMPRESSORA" "tar -xf - -C '$MS_DIR.new'"
    fi
    rsh "set -e; [ -f '$MS_DIR.new/index.html' ]
         [ ! -f '$MS_DIR/config.json' ] || cp -a '$MS_DIR/config.json' '$MS_DIR.new/'
         chmod -R a+rX '$MS_DIR.new'
         [ -d '$MS_DIR-original' ] || cp -a '$MS_DIR' '$MS_DIR-original'
         rm -rf '$MS_DIR.old'
         mv '$MS_DIR' '$MS_DIR.old' && mv '$MS_DIR.new' '$MS_DIR'"
    ok "Mainsail com o painel Chamber instalado. Recarregue a página (Ctrl+F5)."
    echo "    Para voltar ao original: $0 restaurar-mainsail --impressora $IMPRESSORA"
}

cmd_restaurar_mainsail() {
    precisa_impressora
    conectar_impressora
    detectar_mainsail
    rsh_ro "[ -d '$MS_DIR-original' ]" || erro "não existe $MS_DIR-original na impressora."
    confirmar "Voltar o Mainsail para $MS_DIR-original? (a versão atual fica em $MS_DIR.old)" || erro "cancelado."
    rsh "set -e; rm -rf '$MS_DIR.old' && mv '$MS_DIR' '$MS_DIR.old' && cp -a '$MS_DIR-original' '$MS_DIR'"
    ok "Mainsail original restaurado"
}

# ================================================================== status
cmd_status() {
    precisa curl python3
    if sensor_iio >/dev/null; then pi_ler_sensor || aviso "sensor no Pi não respondeu"; else aviso "driver do DHT22 não carregado neste computador"; fi
    curl -fsS --max-time 3 "http://localhost:$PORTA/camara" 2>/dev/null && echo || aviso "serviço não responde em localhost:$PORTA"
    if [[ -n $IMPRESSORA ]]; then
        precisa_impressora
        echo "Klipper: $(mr_json /printer/info 'r["state"]' || echo 'sem resposta do Moonraker')"
        echo "Chamber_Temp: $(mr_json '/printer/objects/query?temperature_sensor%20Chamber_Temp' 'r["status"]["temperature_sensor Chamber_Temp"].get("temperature")' || echo '?')"
        echo "Chamber_Humidity: $(mr_json '/printer/objects/query?temperature_sensor%20Chamber_Humidity' 'r["status"]["temperature_sensor Chamber_Humidity"].get("temperature")' || echo '?')"
    fi
}

# ================================================================== argumentos
[[ $# -gt 0 ]] || uso 1
CMD="$1"; shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --impressora) IMPRESSORA="${2:?}"; shift 2 ;;
        --pi-ip) PI_IP="${2:?}"; shift 2 ;;
        --usuario-ssh) SSH_USER="${2:?}"; shift 2 ;;
        --porta) PORTA="${2:?}"; shift 2 ;;
        --runtime) RUNTIME="${2:?}"; shift 2 ;;
        --tz) TZ_CONTAINER="${2:?}"; shift 2 ;;
        --mainsail-versao) MAINSAIL_VERSAO="${2:?}"; shift 2 ;;
        -y|--sim) SIM=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) uso 0 ;;
        *) erro "opção desconhecida: $1 (veja $0 --help)" ;;
    esac
done
[[ $PORTA =~ ^[0-9]{2,5}$ ]] || erro "porta inválida: $PORTA"
[[ $SSH_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || erro "usuário SSH inválido: $SSH_USER"
[[ $MAINSAIL_VERSAO =~ ^v[0-9.]+$ ]] || erro "versão do Mainsail inválida: $MAINSAIL_VERSAO"
[[ $TZ_CONTAINER =~ ^[A-Za-z0-9_+/-]+$ ]] || erro "fuso inválido: $TZ_CONTAINER"
[[ $DRY_RUN == 1 ]] && aviso "modo --dry-run: nada será alterado"

case "$CMD" in
    pi) cmd_pi ;;
    klipper) cmd_klipper ;;
    mainsail) cmd_mainsail ;;
    status) cmd_status ;;
    desinstalar-klipper) cmd_desinstalar_klipper ;;
    restaurar-mainsail) cmd_restaurar_mainsail ;;
    -h|--help|ajuda) uso 0 ;;
    *) erro "comando desconhecido: $CMD (veja $0 --help)" ;;
esac
