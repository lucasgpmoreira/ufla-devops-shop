# syntax=docker/dockerfile:1

# ---------- Estagio 1: build --- instala as dependencias num venv isolado ----------
FROM python:3.12-alpine AS build

# venv sem pip/setuptools: o que entra aqui vai inteiro para a imagem final
RUN python -m venv --without-pip /opt/venv
COPY requirements.txt .
RUN pip --python /opt/venv/bin/python install --no-cache-dir --no-compile \
        -r requirements.txt \
    && find /opt/venv -name '__pycache__' -prune -exec rm -rf {} +

# ---------- Estagio 2: runtime --- so o interpretador, o venv e o codigo ----------
FROM python:3.12-alpine

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    SQLITE_PATH=/dados/loja.db

# Usuario sem privilegios; /dados e o unico lugar onde a aplicacao escreve
RUN addgroup -S -g 10001 loja \
    && adduser -S -D -H -u 10001 -G loja loja \
    && mkdir /dados && chown loja:loja /dados

WORKDIR /app
COPY --from=build /opt/venv /opt/venv
COPY app/ ./app/
COPY static/ ./static/

USER loja
EXPOSE 8000

# Sem curl na imagem: o proprio Python consulta o /health (liveness)
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).status == 200 else 1)"]

# Forma exec: uvicorn e o PID 1 e recebe o SIGTERM do docker stop
CMD ["uvicorn", "app:api", "--host", "0.0.0.0", "--port", "8000"]
