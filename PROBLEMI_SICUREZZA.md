# Problemi e rischi di `vpn-chain` (spiegati dritti al punto)

> [!WARNING]
> **In soldoni: qual è il problema e cosa si rischia?**
>
> Allora, `vpn-chain` ti dà l'idea di essere blindato dietro due VPN, ma nella versione originale aveva **tre falle belle grosse**:
> 1. **Rischio di uscire in chiaro (Leak):** senza IPv6 bloccato e senza un firewall vero (*kill-switch*), se il secondo tunnel sballa o un sito usa IPv6/DNS esterni, il traffico può passare fuori dalla VPN facendo vedere il tuo IP vero all'ISP.
> 2. **Fiducia cieca nell'immagine di terze parti:** `vpn1` e `vpn2` usano `avpnusr/docker-openvpn:latest` senza digest fissato e con permessi alti (`NET_ADMIN`). Se domani qualcuno compromette quell'immagine su Docker Hub, ha il controllo della rete del container e vede il traffico prima che venga cifrato.
> 3. **Proxy custom troppo permissivo (`proxy.py`):** accettava connessioni verso `127.0.0.1` e reti private (SSRF — cioè un sito o programma poteva fargli bussare ai servizi interni) e non aveva nessun limite di connessioni simultanee (bastano troppe richieste aperte insieme per mandare in blocco tutto il proxy).
>
> **Alla fine della fiera:** per smanettarci in lab ci sta, ma se lo usi per roba seria senza sistemare ste cose rischi un falso senso di sicurezza, capito?

---

## 1. Come funziona (in breve)

Praticamente ci sono tre container che condividono la stessa rete interna (`network_mode: "service:vpn1"`):
1. **`vpn1`** (Hop 1) — apre la prima VPN e pubblica `127.0.0.1:8080:8080`.
2. **`vpn2`** (Hop 2) — gira dentro la rete di `vpn1` con `DEFAULT_GATEWAY=false`.
3. **`proxy_python`** — il proxy SOCKS4/4a scritto in Python ([proxy.py](file:///Users/josephzucchelli/Downloads/vpn-chain/proxy/proxy.py)) che ascolta sulla `8080`.

---

## 2. I problemi uno per uno (senza giri di parole)

### A. Leak IPv6, DNS e Kill-switch un po' fragile
* **IPv6 lasciato acceso:** nel `docker-compose.yml` originale non era disabilitato IPv6. Se la tua rete ha IPv6 e i tunnel gestiscono solo IPv4, quando chiedi un dominio che risponde in IPv6 rischi che il traffico esca dritto fuori dal tunnel.
* **Routing affidato solo ai file `.ovpn`:** `vpn2` usa `DEFAULT_GATEWAY=false` e si fida che le rotte dentro i `.ovpn` facciano tutto il lavoro. Però non c'è un firewall (`iptables`/`nftables`) che blocca il resto: se il secondo hop cade o una rotta è scritta male, il traffico può tornare sul primo hop o uscire sull'ISP.
* **DNS:** `proxy.py` risolve i nomi usando `/etc/resolv.conf` del container `vpn1`. Se lì dentro finisce un DNS locale o dell'ISP invece di quello della VPN, le richieste DNS fanno capire che siti stai cercando.

### B. Immagine di terze parti presa con `:latest`
* **Nessun digest fissato:** `vpn1` e `vpn2` tirano giù `avpnusr/docker-openvpn:latest`. Se il proprietario cambia qualcosa o gli bucano l'account, al prossimo pull ti ritrovi codice nuovo dentro un container che ha `cap_add: [NET_ADMIN]`, `/dev/net/tun` e `security_opt: ["label:disable"]`.
* **Privilegi larghi:** anche **KICS** lo segnala (`Container Capabilities Unrestricted`, severità `MEDIUM`), perché manca `cap_drop: [ALL]` prima di dare `NET_ADMIN`.

### C. Proxy custom senza filtri (`proxy/proxy.py` -> SSRF)
* **Cosa succedeva prima:** `gestisci_connessione()` prendeva l'host chiesto dal client e apriva subito la connessione con `asyncio.open_connection(remote_host, port)`, senza controllare dove puntava quell'IP.
* **Il rischio pratico:** dal browser o da un processo sulla macchina qualcuno poteva far puntare il proxy a `127.0.0.1` o a IP privati (`192.168.x.x`, `172.x.x.x`, `10.x.x.x`). Nei nostri test locali infatti rispondeva `0x5a` (consentito) e ci ha proprio rimandato indietro `b'INTERNAL:ping'` dal server fittizio locale.

### D. Nessun freno sulle connessioni (DoS locale)
* **Cosa succedeva prima:** `asyncio.start_server` accettava tutte le connessioni senza un tetto massimo.
* **Il rischio pratico:** se un browser impallato, una pagina web pesante o uno script apre troppe connessioni insieme e le lascia appese, finiscono i *file descriptor* del container (`Too many open files`) e si inchioda il proxy per tutti finché non scattano i timeout (10–15s) o Docker non lo riavvia.

### E. Dettagli di contorno da sistemare
* **Codice del proxy montato in scrittura:** prima `./proxy:/app` non aveva `:ro`, quindi da dentro il container i file erano modificabili.
* **Pacchetto non pinnato:** in `proxy/Dockerfile`, `apk add --no-cache curl` non fissa la versione di `curl` (segnalato da **KICS** come `Unpinned Package Version in Apk Add`, severità `MEDIUM`).
* **SOCKS4/4a:** è un protocollo vecchio, senza autenticazione né UDP/IPv6 nativo (rispetto a SOCKS5).

---

## 3. A che punto siamo adesso nella copia locale

Abbiamo già messo mano ai file qui in locale e verificato tutto con `./audit_check.sh`, **Trivy** (`0.76.2`) e **KICS** (`2.2.1`):

| Controllo | Prima | Adesso | Come l'abbiamo sistemato |
|---|---|---|---|
| Filtro anti-SSRF su `proxy.py` | `[WARN]` Loopback aperto (`0x5a`) | `[OK]` Bloccato (`0x5b`) | Aggiunta `risolvi_e_valida()` con `ipaddress.is_global` |
| Limite connessioni simultanee | `[WARN]` Infinito | `[OK]` Max 100 | Aggiunto `MAX_CONNS = asyncio.Semaphore(100)` |
| IPv6 disabilitato nel compose | `[WARN]` Acceso | `[OK]` Spento | Aggiunti `sysctls` su `vpn1` |
| Codice proxy in sola lettura | `[WARN]` RW | `[OK]` `:ro` | Cambiato in `./proxy:/app:ro` |
| Immagini senza `:latest` | `[WARN]` Usa `:latest` | `[WARN]` Ancora `:latest` | Da fissare con `@sha256:...` o `Dockerfile` tuo |
| `cap_drop: [ALL]` su `vpn1`/`vpn2` | `[WARN]` Segnalato da KICS | `[WARN]` Segnalato da KICS | Da mettere prima di `cap_add: [NET_ADMIN]` |
| Firewall Kill-Switch (`iptables`) | `[WARN]` Assente | `[WARN]` Assente | Da aggiungere nello startup VPN |

---

## 4. Come lanciare il controllo quando ti pare

Vai nella cartella e fai girare lo script:

```bash
cd ~/Downloads/vpn-chain
./audit_check.sh
```

Ti fa in automatico: controllo sintassi Compose e `vpn.sh`, test che `127.0.0.1` sia bloccato (`0x5b`), check statici sul `docker-compose.yml`, scan **Trivy** (`0` problemi su `proxy/Dockerfile`) e scan **KICS** (`0` Critical, `0` High, `5` Medium residui).

---

*Nota: questa analisi di sicurezza e le relative patch di hardening sono state realizzate con il supporto di un team multi-agente di AI.*
