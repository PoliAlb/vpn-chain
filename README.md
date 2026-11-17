# Catena di VPN con container Docker

Setup per instradare il traffico attraverso due hop OpenVPN annidati (`vpn1` -> `vpn2`) ed esporre un proxy SOCKS4/4a locale (`127.0.0.1:8080`) nel network namespace condiviso.

## Uso rapido (`vpn.sh`)

`vpn.sh` prepara le configurazioni, avvia i container e verifica il doppio hop (lavora nella cartella in cui si trova lo script):

```text
./vpn.sh [up] [--force]     prepara + docker compose up + attesa + verifica (default)
./vpn.sh prepare [--force]    solo conf (rigenera se mancano o il cert sta per scadere)
./vpn.sh check                solo verifica di un setup già avviato
./vpn.sh down                 docker compose down
./vpn.sh logs [servizio]      segue i log (vpn1, vpn2, proxy_python)
```

### Variabili opzionali
* `GEN_OPTS`: default `--no-ipv6` (`""` per abilitare IPv6)
* `PROXY_PORT`: default `8080`
* `CERT_MIN_DAYS`: default `3`
* `WAIT_SECS`: default `240`
