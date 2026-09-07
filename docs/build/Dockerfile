FROM python:3.12-alpine

WORKDIR /app

# Copiamo prima solo requirements.txt per sfruttare la cache dei layer Docker:
# se in futuro cambia solo proxy.py, questo layer non viene rieseguito.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Il codice vero e proprio arriva tramite volume in docker-compose.yml,
# non serve un COPY qui per proxy.py (resta modificabile senza rebuild).

CMD ["python", "proxy.py"]
