# Catena di VPN con container Docker

## TOR È STATO COMPROMESSO !

- https://www.reddit.com/r/TOR/comments/rrbs75/tor_has_been_compromised_for_years/
- https://www.malwarebytes.com/blog/news/2024/09/tor-anonymity-compromised-by-law-enforcement-is-it-still-safe-to-use
- https://medium.com/codex/the-darkweb-is-being-compromised-e220ae43976b
- https://www.washingtonpost.com/world/national-security/secret-nsa-documents-show-campaign-against-tor-encrypted-network/2013/10/04/610f08b6-2d05-11e3-8ade-a1f23cda135e_story.html
- https://cyberinsider.com/tor/

Questi sono solo alcune delle testimonianze che l'infrastruttura della rete Tor alla fine è crollata. Non demordiamo, la libertà è ancora possibile. Gli hop sono due
e l'anonimato è garantito anche se non avremo i bridge a disposizione, quindi la fase di handshake sarà completamente visibile all'ISP. Inoltre i siti con 
dominio .onion rimango accessibili tramite Tor, che se incapsulato nella catena rallenterà il traffico notevolmente.


vpn.sh - tutto in uno: prepara le conf, avvia i container, verifica il doppio hop.

 Uso (da qualunque cartella: lavora nella cartella in cui si trova lo script):
   ./vpn.sh [up] [--force]   prepara + docker compose up + attesa + verifica   (default)
   ./vpn.sh prepare [--force]  solo conf (rigenera se mancano o il cert sta per scadere)
   ./vpn.sh check            solo verifica di un setup gia' avviato
   ./vpn.sh down             docker compose down
   ./vpn.sh logs [servizio]  segue i log (vpn1, vpn2, proxy_python)

Variabili opzionali: GEN_OPTS (default "--no-ipv6"; "" per abilitare IPv6), PROXY_PORT (8080), CERT_MIN_DAYS (3), WAIT_SECS (240)


Il codice è stato generato da ClaudeAI perché lui è più bravo di me.
