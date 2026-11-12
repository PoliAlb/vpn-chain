FROM python:3.12-alpine

WORKDIR /app

RUN apk add --no-cache curl

# Il codice vero e proprio arriva tramite volume in docker-compose.yml,
# non serve un COPY qui per proxy.py (resta modificabile senza rebuild).

CMD ["python", "proxy.py"]