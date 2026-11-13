FROM python:3.12-alpine

WORKDIR /app

# curl serve a vpn.sh (check dell'IP di uscita via "docker exec").
# Utente non-root senza shell/home: il proxy ascolta su 8080 (>1024), non servono privilegi.
RUN apk add --no-cache curl \
    && adduser -D -H -s /sbin/nologin -u 10001 proxy

USER proxy

# Il codice vero e proprio arriva tramite volume in docker-compose.yml,
# non serve un COPY qui per proxy.py (resta modificabile senza rebuild).

# Healthcheck: la porta del proxy accetta connessioni?
# (la connessione chiusa subito e' gestita in silenzio da proxy.py)
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD python -c "import socket; socket.create_connection(('127.0.0.1', 8080), 3).close()"

CMD ["python", "proxy.py"]