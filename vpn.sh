#!/usr/bin/env bash
#
# vpn.sh - tutto in uno: prepara le conf, avvia i container, verifica il doppio hop.
#
# Uso (da qualunque cartella: lavora nella cartella in cui si trova lo script):
#   ./vpn.sh [up] [--force]   prepara + docker compose up + attesa + verifica   (default)
#   ./vpn.sh prepare [--force]  solo conf (rigenera se mancano o il cert sta per scadere)
#   ./vpn.sh check            solo verifica di un setup gia' avviato
#   ./vpn.sh down             docker compose down
#   ./vpn.sh logs [servizio]  segue i log (vpn1, vpn2, proxy_python)
#
# Variabili opzionali: GEN_OPTS (default "--no-ipv6"; "" per abilitare IPv6), PROXY_PORT (8080),
#                      CERT_MIN_DAYS (3), WAIT_SECS (240)
#
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cartella con docker-compose.yml, proxy/ e vpn{1,2}-config/: quella dello script
# (se ci sta gia' un compose o non c'e' altro), oppure ./docs/build se esiste.
if [ -f "$SELF_DIR/docker-compose.yml" ] || [ ! -f "$SELF_DIR/docs/build/docker-compose.yml" ]; then
    BUILD_DIR="$SELF_DIR"
else
    BUILD_DIR="$SELF_DIR/docs/build"
fi

VPN1=vpn1; VPN2=vpn2; PROXY=proxy_python
PROXY_PORT="${PROXY_PORT:-8080}"
GEN_OPTS="${GEN_OPTS:---no-ipv6}"
CERT_MIN_DAYS="${CERT_MIN_DAYS:-3}"
WAIT_SECS="${WAIT_SECS:-240}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAILURES=$((FAILURES+1)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
info() { echo -e "==> $1"; }
die()  { echo -e "${RED}[ERRORE]${NC} $1" >&2; exit 1; }
FAILURES=0

# ------------------------------------------------------------------ prepare --

# 0 = cert valido per almeno CERT_MIN_DAYS, 1 = mancante/scaduto/in scadenza
cert_ok() {
    local conf="$1"
    [ -f "$conf" ] || return 1
    if ! command -v openssl >/dev/null 2>&1; then
        warn "openssl non trovato: salto il controllo di scadenza del certificato."
        return 0
    fi
    sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$conf" \
        | openssl x509 -noout -checkend $((CERT_MIN_DAYS * 86400)) >/dev/null 2>&1
}

# Se mancano compose/proxy nella cartella, li crea: lo script e' autosufficiente.
ensure_files() {
    mkdir -p "$BUILD_DIR/proxy"
    if [ ! -f "$BUILD_DIR/docker-compose.yml" ]; then
        info "Creo docker-compose.yml"
        cat > "$BUILD_DIR/docker-compose.yml" <<'EOF_COMPOSE'
services:
  # --- HOP 1 ---
  vpn1:
    image: avpnusr/docker-openvpn:latest
    container_name: vpn1
    cap_add: [NET_ADMIN]
    devices: [/dev/net/tun]
    security_opt: ["label:disable"]
    volumes:
      - ./vpn1-config:/vpn
    # La porta del proxy va pubblicata QUI: vpn2 e proxy_python usano il netns
    # di vpn1 e non possono avere "ports:" proprie.
    # 127.0.0.1 = non esporre un proxy aperto alla tua LAN.
    ports:
      - "127.0.0.1:8080:8080"
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "ip addr show tun0 | grep -q inet && ping -c1 -W5 1.1.1.1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  # --- HOP 2 (annidato in vpn1) ---
  vpn2:
    image: avpnusr/docker-openvpn:latest
    container_name: vpn2
    cap_add: [NET_ADMIN]
    devices: [/dev/net/tun]
    security_opt: ["label:disable"]
    environment:
      - DEFAULT_GATEWAY=false   # l'instradamento lo fa la conf (route /2)
    volumes:
      - ./vpn2-config:/vpn
    network_mode: "service:vpn1"
    depends_on:
      vpn1:
        condition: service_healthy
    restart: unless-stopped
    healthcheck:
      # il ping qui non servirebbe: il netns e' lo stesso di vpn1.
      # Verifichiamo invece che tun1 esista e abbia un IP.
      test: ["CMD-SHELL", "ip addr show tun1 | grep -q inet"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 45s

  # --- Proxy SOCKS4/4a ---
  proxy_python:
    build: ./proxy
    container_name: proxy_python
    working_dir: /app
    volumes:
      - ./proxy:/app
    network_mode: "service:vpn1"   # stesso netns; le rotte di vpn2 valgono anche qui
    depends_on:
      vpn2:
        condition: service_healthy
    restart: unless-stopped
EOF_COMPOSE
    fi
    if [ ! -f "$BUILD_DIR/proxy/Dockerfile" ]; then
        info "Creo proxy/Dockerfile"
        cat > "$BUILD_DIR/proxy/Dockerfile" <<'EOF_DOCKERFILE'
FROM python:3.12-alpine

WORKDIR /app

RUN apk add --no-cache curl

# Il codice vero e proprio arriva tramite volume in docker-compose.yml,
# non serve un COPY qui per proxy.py (resta modificabile senza rebuild).

CMD ["python", "proxy.py"]
EOF_DOCKERFILE
    fi
    if [ ! -f "$BUILD_DIR/proxy/proxy.py" ]; then
        info "Creo proxy/proxy.py"
        cat > "$BUILD_DIR/proxy/proxy.py" <<'EOF_PROXY'
import asyncio
import socket
import struct

LISTEN_HOST = '0.0.0.0'
LISTEN_PORT = 8080

REPLY_OK = b'\x00\x5a\x00\x00\x00\x00\x00\x00'
REPLY_FAIL = b'\x00\x5b\x00\x00\x00\x00\x00\x00'


async def inoltra(reader, writer):
    """Sposta i byte da 'reader' a 'writer' finché una delle due parti chiude."""
    try:
        while True:
            chunk = await reader.read(4096)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, OSError) as e:
        print(f"Connessione interrotta durante l'inoltro: {e}")
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except OSError:
            pass


async def gestisci_connessione(local_reader, local_writer):
    remote_writer = None
    try:
        # Header SOCKS4: VN(1) CD(1) DSTPORT(2) DSTIP(4)
        data = await local_reader.readexactly(8)
        version, command, port, ip_bytes = struct.unpack('!BBH4s', data)

        # FIX 1: dopo l'header ci sono USERID (lunghezza variabile) + NUL.
        # Il codice originale non li leggeva: il NUL finiva nel flusso dati
        # e il server remoto vedeva "\x00GET ..." -> 501 / connessione rotta.
        await asyncio.wait_for(local_reader.readuntil(b'\x00'), timeout=10)

        if version != 4 or command != 1:
            local_writer.write(REPLY_FAIL)
            await local_writer.drain()
            return

        # FIX 2: SOCKS4a. Se l'IP è 0.0.0.x (x != 0) il client manda il
        # NOME HOST dopo lo userid, e la risoluzione DNS la facciamo qui,
        # DENTRO la VPN (niente DNS leak lato client).
        if ip_bytes[:3] == b'\x00\x00\x00' and ip_bytes[3] != 0:
            raw = await asyncio.wait_for(local_reader.readuntil(b'\x00'), timeout=10)
            remote_host = raw[:-1].decode('ascii', errors='replace')
        else:
            remote_host = socket.inet_ntoa(ip_bytes)

        try:
            remote_reader, remote_writer = await asyncio.wait_for(
                asyncio.open_connection(remote_host, port), timeout=15)
        except (OSError, asyncio.TimeoutError) as e:
            print(f"Connessione remota fallita verso {remote_host}:{port} -> {e!r}")
            local_writer.write(REPLY_FAIL)
            await local_writer.drain()
            return

        local_writer.write(REPLY_OK)
        await local_writer.drain()

        task1 = asyncio.create_task(inoltra(local_reader, remote_writer))
        task2 = asyncio.create_task(inoltra(remote_reader, local_writer))
        await asyncio.gather(task1, task2, return_exceptions=True)

    except (asyncio.IncompleteReadError, asyncio.TimeoutError, asyncio.LimitOverrunError):
        pass  # client che chiude/handshake incompleto: normale, niente rumore
    except Exception as e:
        print(f"Errore: {e!r}")
    finally:
        local_writer.close()
        if remote_writer is not None:
            remote_writer.close()


async def main():
    server = await asyncio.start_server(gestisci_connessione, LISTEN_HOST, LISTEN_PORT)
    print(f"SOCKS4/4a in ascolto su {LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == '__main__':
    asyncio.run(main())
EOF_PROXY
    fi
}

# Equivalente integrato di generate.sh (RiseupVPN-OpenVPN): scarica certificato,
# CA e lista gateway dall'API Riseup e scrive la conf in $1.
# Opzioni (da GEN_OPTS): --no-ipv6
generate_conf() {
    local out="$1" tool key_cert ca_cert remotes
    for tool in curl jq; do
        command -v "$tool" >/dev/null 2>&1 || { echo "Manca '$tool' (es. apt install -y jq curl)"; return 1; }
    done
    local curl_opts=(-sS --fail --connect-timeout 10 --retry 3)

    echo "Scarico certificato, CA e lista server (l'API Riseup puo' essere lenta)..."
    key_cert=$(curl "${curl_opts[@]}" -H "Accept: text/html" https://api.black.riseup.net/3/cert) || return 1
    ca_cert=$(curl "${curl_opts[@]}" -H "Accept: text/html" https://black.riseup.net/ca.crt) || return 1
    remotes=$(curl "${curl_opts[@]}" -H "Accept: application/json" https://api.black.riseup.net/3/config/eip-service.json \
        | jq -r '.gateways[] | . as $g | $g.capabilities.transport[]
                 | select(.type | contains("openvpn")) | .ports[] as $p
                 | "remote \($g.ip_address) \($p) # \($g.host) (\($g.location))"') || return 1
    [ -n "$remotes" ] || { echo "Nessun gateway OpenVPN nella risposta Riseup."; return 1; }
    echo "$key_cert" | grep -q 'BEGIN CERTIFICATE' || { echo "Risposta /3/cert senza certificato."; return 1; }

    {
        cat <<'EOF_CONF_HEAD'
client

dev tun
proto tcp
nobind

# Riseup available servers
EOF_CONF_HEAD
        echo "$remotes"
        cat <<'EOF_CONF_TAIL'
remote-random

# Quick reconnect
persist-key
persist-tun
pull-filter ignore "ping"
pull-filter ignore "ping-restart"
pull-filter ignore "keepalive"
keepalive 10 20
server-poll-timeout 10
connect-retry 1 2
connect-retry-max 1

# Cipher
cipher AES-256-GCM
data-ciphers AES-256-GCM
remote-cert-tls server

verb 1
EOF_CONF_TAIL
        printf '\n<key>\n%s\n</key>\n' "$(echo "$key_cert" | sed -e '/BEGIN RSA/,/END RSA/!d')"
        printf '\n<cert>\n%s\n</cert>\n' "$(echo "$key_cert" | sed -e '/BEGIN CERTIFICATE/,/END CERTIFICATE/!d')"
        printf '\n<ca>\n%s\n</ca>\n' "$ca_cert"
        case " $GEN_OPTS " in *" --no-ipv6 "*)
            cat <<'EOF_NOIPV6'

# Disable IPv6
pull-filter ignore "tun-ipv6"
pull-filter ignore "route-ipv6"
pull-filter ignore "ifconfig-ipv6"
pull-filter ignore "redirect-gateway"
block-ipv6
redirect-gateway def1
EOF_NOIPV6
        ;; esac
    } > "$out"
    chmod 600 "$out"
}

split_hops() {
    local src="$1"
    mkdir -p "$BUILD_DIR/vpn1-config" "$BUILD_DIR/vpn2-config"
    local o1="$BUILD_DIR/vpn1-config/riseup-ovpn.conf"
    local o2="$BUILD_DIR/vpn2-config/riseup-ovpn.conf"

    # Server divisi per HOST in due gruppi disgiunti (vpn1 e vpn2 non
    # possono mai pescare lo stesso gateway).
    awk -v out1="$o1" -v out2="$o2" '
    /^remote [0-9]/ { host=$5; if (!(host in idx)) idx[host]=++n
                      if (idx[host]%2) print > out1; else print > out2; next }
    /^redirect-gateway/ { print > out1; next }   # solo hop 1: vpn2 usa le rotte /2 piu` sotto
    { print > out1; print > out2 }' "$src"
    chmod 600 "$o1" "$o2"

    cat >> "$o2" <<'EOT'

# ---- HOP 2: vpn2 vive nello stesso netns di vpn1 ----
# Evita il conflitto con le rotte /1 di vpn1 e impedisce che il server di
# vpn2 venga raggiunto via eth0 (che taglierebbe fuori vpn1).
route-nopull
pull-filter ignore "redirect-gateway"
pull-filter ignore "dhcp-option"
pull-filter ignore "block-outside-dns"
script-security 2
up /vpn/hop2-up.sh
route 0.0.0.0   192.0.0.0 vpn_gateway
route 64.0.0.0  192.0.0.0 vpn_gateway
route 128.0.0.0 192.0.0.0 vpn_gateway
route 192.0.0.0 192.0.0.0 vpn_gateway
EOT

    cat > "$BUILD_DIR/vpn2-config/hop2-up.sh" <<'EOT'
#!/bin/sh
# Il server di vpn2 deve restare raggiungibile via tun0 (vpn1), non via tun1.
ip route replace "${trusted_ip}/32" dev tun0
EOT
    chmod +x "$BUILD_DIR/vpn2-config/hop2-up.sh"
}

cmd_prepare() {
    local force="${1:-}"
    ensure_files
    local gen_conf="$BUILD_DIR/riseup-ovpn.conf"
    local hop1="$BUILD_DIR/vpn1-config/riseup-ovpn.conf"

    if [ "$force" != "--force" ] && cert_ok "$hop1" && [ -f "$BUILD_DIR/vpn2-config/riseup-ovpn.conf" ]; then
        pass "Conf esistenti con certificato valido (>= ${CERT_MIN_DAYS} giorni): non rigenero. (--force per forzare)"
        return 0
    fi

    info "Genero una nuova conf Riseup (cert mancante/scaduto/in scadenza o --force)..."
    generate_conf "$gen_conf" || die "Generazione della conf Riseup fallita."
    cert_ok "$gen_conf" || die "Il certificato appena scaricato risulta non valido."

    info "Creo vpn1-config/ e vpn2-config/ in $BUILD_DIR"
    split_hops "$gen_conf"
    pass "Conf pronte: vpn1 $(grep -c '^remote [0-9]' "$hop1") righe server, vpn2 $(grep -c '^remote [0-9]' "$BUILD_DIR/vpn2-config/riseup-ovpn.conf")."
}

# -------------------------------------------------------------------- check --

# IP pubblico visto da un container (primo tool disponibile: curl, wget, python3)
get_public_ip() {
    local c="$1" ip=""
    ip=$(docker exec "$c" curl -s --max-time 10 ipinfo.io/ip 2>/dev/null)
    [ -z "$ip" ] && ip=$(docker exec "$c" wget -qO- -T 10 ipinfo.io/ip 2>/dev/null)
    [ -z "$ip" ] && ip=$(docker exec "$c" python3 -c "import urllib.request;print(urllib.request.urlopen('https://ipinfo.io/ip',timeout=10).read().decode().strip())" 2>/dev/null)
    echo "$ip"
}

cmd_check() {
    FAILURES=0
    echo "== Verifica doppio hop: $VPN1 -> $VPN2 (+ $PROXY) =="

    # 1. container attivi
    local c
    for c in "$VPN1" "$VPN2" "$PROXY"; do
        if docker ps --format '{{.Names}}' | grep -qx "$c"; then pass "Container '$c' in esecuzione."
        else fail "Container '$c' NON in esecuzione."; fi
    done
    [ "$FAILURES" -gt 0 ] && { echo; fail "Container mancanti: salto il resto."; return 1; }

    # 2. log OpenVPN
    for c in "$VPN1" "$VPN2"; do
        if docker logs "$c" 2>&1 | grep -q "Initialization Sequence Completed"; then
            pass "$c: tunnel inizializzato (log)."
        else fail "$c: nessun 'Initialization Sequence Completed' nei log."; fi
    done

    # 3. interfacce
    local dev ip
    for dev in tun0 tun1; do
        ip=$(docker exec "$VPN1" ip -4 addr show "$dev" 2>/dev/null | grep -oP '(?<=inet )[\d.]+')
        if [ -n "$ip" ]; then pass "$dev presente (IP $ip)  [$( [ "$dev" = tun0 ] && echo hop 1 || echo hop 2 )]."
        else fail "$dev assente o senza IP."; fi
    done

    # 4. routing: la destinazione qualunque deve uscire da tun1; il server di vpn2 da tun0
    local routes
    routes=$(docker exec "$VPN1" ip route 2>/dev/null)
    if docker exec "$VPN1" ip route get 8.8.8.8 2>/dev/null | grep -q "dev tun1"; then
        pass "Il traffico verso Internet esce da tun1 (hop 2)."
    else fail "Il traffico verso Internet NON passa da tun1: $(docker exec "$VPN1" ip route get 8.8.8.8 2>/dev/null | head -1)"; fi
    if echo "$routes" | grep -qE '^0\.0\.0\.0/1.*tun0|^default.*tun0'; then
        pass "Rotte di vpn1 (0.0.0.0/1 + 128.0.0.0/1 via tun0) presenti: l'hop 2 viaggia dentro l'hop 1."
    else fail "Mancano le rotte di vpn1 via tun0."; fi
    if echo "$routes" | grep -qE '^[0-9.]+ dev tun0'; then
        pass "Host route del server di vpn2 via tun0 (hop2-up.sh ha funzionato)."
    else fail "Manca la host route '<server vpn2> dev tun0': hop2-up.sh non e' stato eseguito (script-security? permessi?)."; fi

    # 5. IP: host reale vs uscita vs proxy
    local host_ip exit_ip proxy_ip
    host_ip=$(curl -s --max-time 8 ipinfo.io/ip 2>/dev/null)
    exit_ip=$(get_public_ip "$VPN1")
    if [ -z "$exit_ip" ]; then fail "Impossibile ottenere l'IP di uscita da $VPN1."
    elif [ -n "$host_ip" ] && [ "$exit_ip" = "$host_ip" ]; then fail "IP di uscita ($exit_ip) == IP reale dell'host: NESSUNA VPN attiva!"
    else pass "IP di uscita: $exit_ip${host_ip:+ (IP reale host: $host_ip)}"; fi

    proxy_ip=$(get_public_ip "$PROXY")
    if [ -z "$proxy_ip" ]; then warn "Nessun tool HTTP in $PROXY: impossibile confrontare l'IP (condivide comunque il netns di $VPN1)."
    elif [ "$proxy_ip" = "$exit_ip" ]; then pass "$PROXY esce con lo stesso IP ($proxy_ip)."
    else fail "$PROXY esce con IP diverso ($proxy_ip) da $VPN1 ($exit_ip)."; fi

    # 6. proxy dall'host (SOCKS4a: DNS risolto dentro la VPN)
    local sip
    sip=$(curl -s --max-time 15 --socks4a "127.0.0.1:$PROXY_PORT" https://ipinfo.io/ip 2>/dev/null)
    if [ -z "$sip" ]; then fail "Il proxy su 127.0.0.1:$PROXY_PORT non risponde (porta pubblicata su $VPN1? proxy avviato?)."
    elif [ "$sip" = "$exit_ip" ]; then pass "Proxy SOCKS4a dall'host OK: esce con $sip."
    else fail "Il proxy esce con $sip, atteso $exit_ip."; fi

    # 7. DNS e IPv6
    local dns
    dns=$(docker exec "$VPN1" grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    [ -n "$dns" ] && warn "DNS nel netns: $dns (verifica che non siano quelli del tuo ISP; con SOCKS4a il proxy risolve da qui)."
    local v6
    v6=$(docker exec "$VPN1" curl -6 -s --max-time 5 https://ifconfig.co 2>/dev/null)
    if [ -z "$v6" ]; then pass "Nessun IPv6 pubblico raggiungibile."
    else warn "IPv6 pubblico raggiungibile ($v6): possibile leak, usa --no-ipv6."; fi

    echo
    if [ "$FAILURES" -eq 0 ]; then pass "Tutti i controlli superati."; return 0
    else fail "$FAILURES controllo/i falliti."; return 1; fi
}

# ----------------------------------------------------------------- up/down ---

compose() {
    if docker compose version >/dev/null 2>&1; then docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then docker-compose "$@"
    else die "Ne' 'docker compose' ne' 'docker-compose' disponibili."; fi
}

wait_healthy() {
    local c="$1" t=0 st
    info "Attendo che '$c' diventi healthy (max ${WAIT_SECS}s)..."
    while [ "$t" -lt "$WAIT_SECS" ]; do
        st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}nohealth{{end}}' "$c" 2>/dev/null || echo missing)
        [ "$st" = healthy ] && { pass "'$c' healthy dopo ${t}s."; return 0; }
        sleep 3; t=$((t+3))
    done
    fail "'$c' non e' diventato healthy (stato: $st). Ultime righe di log:"
    docker logs --tail 25 "$c" 2>&1 | sed 's/^/    /'
    return 1
}

cmd_up() {
    cmd_prepare "${1:-}"
    info "docker compose up -d --build"
    ( cd "$BUILD_DIR" && compose up -d --build ) || die "docker compose up e' fallito."
    wait_healthy "$VPN1" || exit 1
    wait_healthy "$VPN2" || exit 1
    sleep 3
    echo
    cmd_check
    local rc=$?
    echo
    info "Proxy: socks4a://127.0.0.1:$PROXY_PORT   (es.: curl --socks4a 127.0.0.1:$PROXY_PORT https://ipinfo.io/ip)"
    info "Cartella di lavoro: $BUILD_DIR"
    return $rc
}

cmd_down() { ( cd "$BUILD_DIR" && compose down ); }
cmd_logs() { ( cd "$BUILD_DIR" && compose logs -f --tail 50 "$@" ); }

# --------------------------------------------------------------------- main --

case "${1:-}" in prepare|help|-h|--help) ;; *) command -v docker >/dev/null 2>&1 || die "docker non trovato." ;; esac
case "${1:-up}" in
    up)      shift || true; cmd_up "${1:-}"; exit $? ;;
    --force) cmd_up --force ;;
    prepare) shift; cmd_prepare "${1:-}" ;;
    check)   cmd_check; exit $? ;;
    down)    cmd_down ;;
    logs)    shift; cmd_logs "$@" ;;
    -h|--help|help) sed -n '2,16p' "$0" ;;
    *)       echo "Uso: $0 [up|prepare|check|down] [--force]"; exit 2 ;;
esac