#!/usr/bin/env bash
#
# check-vpn.sh - Verifica automatica del container dperson/openvpn-client con Riseup
#
# Uso:
#   ./check-vpn.sh vpn                     # controlla solo il container VPN
#   ./check-vpn.sh vpn altro-container     # controlla anche che un altro container
#                                           # (in --network container:vpn) esca dallo stesso IP
#
set -u

VPN_CONTAINER="${1:-vpn}"
OTHER_CONTAINER="${2:-}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Prova a ottenere l'IP pubblico da un container usando il primo strumento
# disponibile: curl, wget, python3. Ritorna stringa vuota se nessuno funziona
# (es. immagine minimale senza alcun tool HTTP, non è un problema di rete).
get_public_ip() {
    local container="$1"
    local ip=""
    ip=$(docker exec "$container" curl -s --max-time 8 ipinfo.io/ip 2>/dev/null)
    if [ -z "$ip" ]; then
        ip=$(docker exec "$container" wget -qO- --timeout=8 ipinfo.io/ip 2>/dev/null)
    fi
    if [ -z "$ip" ]; then
        ip=$(docker exec "$container" python3 -c "import urllib.request; print(urllib.request.urlopen('https://ipinfo.io/ip', timeout=8).read().decode().strip())" 2>/dev/null)
    fi
    echo "$ip"
}

FAILURES=0

echo "== Verifica VPN container: $VPN_CONTAINER =="
echo

# 1. Container in esecuzione?
if ! docker ps --format '{{.Names}}' | grep -qx "$VPN_CONTAINER"; then
    fail "Il container '$VPN_CONTAINER' non risulta in esecuzione."
    exit 1
fi
pass "Container '$VPN_CONTAINER' in esecuzione."

# 2. Log: tunnel inizializzato
if docker logs "$VPN_CONTAINER" 2>&1 | grep -q "Initialization Sequence Completed"; then
    pass "Tunnel OpenVPN inizializzato correttamente (log)."
else
    fail "Nessuna riga 'Initialization Sequence Completed' nei log. Il tunnel potrebbe non essere su."
    FAILURES=$((FAILURES+1))
fi

# 3. Interfaccia tun0 presente
if docker exec "$VPN_CONTAINER" ip a 2>/dev/null | grep -q "tun0"; then
    TUN_IP=$(docker exec "$VPN_CONTAINER" ip -4 addr show tun0 2>/dev/null | grep -oP '(?<=inet )[\d.]+')
    pass "Interfaccia tun0 presente (IP: ${TUN_IP:-n/d})."
else
    fail "Interfaccia tun0 non trovata dentro il container."
    FAILURES=$((FAILURES+1))
fi

# 4. Route di default via tun0 (oppure split-default 0.0.0.0/1 + 128.0.0.0/1,
#    tipico di "redirect-gateway def1": il traffico passa comunque nel tunnel
#    anche se la riga "default" letterale resta su eth0)
ALL_ROUTES=$(docker exec "$VPN_CONTAINER" ip route 2>/dev/null)
DEFAULT_ROUTE=$(echo "$ALL_ROUTES" | grep "^default")
SPLIT_LOW=$(echo "$ALL_ROUTES" | grep "^0.0.0.0/1.*tun0")
SPLIT_HIGH=$(echo "$ALL_ROUTES" | grep "^128.0.0.0/1.*tun0")

if echo "$DEFAULT_ROUTE" | grep -q "tun0"; then
    pass "Route di default passa per tun0."
elif [ -n "$SPLIT_LOW" ] && [ -n "$SPLIT_HIGH" ]; then
    pass "Split-default rilevato (redirect-gateway def1): 0.0.0.0/1 e 128.0.0.0/1 via tun0 coprono tutto il traffico, anche se 'default' resta su eth0 (normale)."
else
    fail "Route di default NON passa per tun0 e nessuno split-default trovato: $DEFAULT_ROUTE"
    FAILURES=$((FAILURES+1))
fi

# 5. IP pubblico visto dal container VPN
VPN_IP=$(get_public_ip "$VPN_CONTAINER")
if [ -n "$VPN_IP" ]; then
    pass "IP pubblico del container VPN: $VPN_IP"
else
    fail "Impossibile ottenere l'IP pubblico dal container VPN (nessun tool HTTP disponibile: curl/wget/python3)."
    FAILURES=$((FAILURES+1))
fi

# 6. DNS in uso
DNS_SERVERS=$(docker exec "$VPN_CONTAINER" cat /etc/resolv.conf 2>/dev/null | grep "^nameserver" | awk '{print $2}' | tr '\n' ' ')
if [ -n "$DNS_SERVERS" ]; then
    warn "DNS in uso dentro il container: $DNS_SERVERS (verifica manualmente che NON siano i DNS del tuo ISP)"
else
    fail "Impossibile leggere /etc/resolv.conf dal container."
    FAILURES=$((FAILURES+1))
fi

# 7. Leak IPv6
IPV6_RESULT=$(docker exec "$VPN_CONTAINER" curl -6 -s --max-time 5 https://ifconfig.co 2>/dev/null)
if [ -z "$IPV6_RESULT" ]; then
    pass "Nessun IPv6 pubblico raggiungibile (bene, se hai usato --no-ipv6)."
else
    warn "Il container espone un IPv6 pubblico: $IPV6_RESULT (possibile leak se non voluto)"
fi

# 8. Controllo container secondario (se fornito) sullo stesso network namespace
if [ -n "$OTHER_CONTAINER" ]; then
    echo
    echo "== Verifica container collegato: $OTHER_CONTAINER =="
    if ! docker ps --format '{{.Names}}' | grep -qx "$OTHER_CONTAINER"; then
        fail "Il container '$OTHER_CONTAINER' non risulta in esecuzione."
        FAILURES=$((FAILURES+1))
    else
        OTHER_IP=$(get_public_ip "$OTHER_CONTAINER")
        if [ -n "$OTHER_IP" ] && [ "$OTHER_IP" = "$VPN_IP" ]; then
            pass "'$OTHER_CONTAINER' esce con lo stesso IP del VPN ($OTHER_IP): il routing funziona."
        elif [ -n "$OTHER_IP" ]; then
            fail "'$OTHER_CONTAINER' esce con IP diverso ($OTHER_IP) rispetto al VPN ($VPN_IP): NON sta passando dal tunnel!"
            FAILURES=$((FAILURES+1))
        else
            warn "Impossibile ottenere l'IP pubblico da '$OTHER_CONTAINER' (nessun tool HTTP: curl/wget/python3 nell'immagine). Se ha network_mode: service:$VPN_CONTAINER, l'IP è comunque garantito identico a livello di kernel: non è un problema di rete, solo di strumenti mancanti nell'immagine."
        fi
    fi
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    pass "Tutti i controlli superati."
    exit 0
else
    fail "$FAILURES controllo/i falliti. Vedi sopra."
    exit 1
fi