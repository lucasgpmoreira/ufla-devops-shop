#!/usr/bin/env bash
#
# Instala o ufla-devops-shop como servico do systemd, com Nginx na frente.
# Pode ser rodado quantas vezes quiser: nada aqui duplica nada.
#
#   sudo ./scripts/deploy.sh
#
set -euo pipefail

USUARIO=ufla-shop
DESTINO=/opt/ufla-shop
ENV_FILE=/etc/ufla-shop.env
ENV_MODELO=/etc/ufla-shop.env.example
CERT_DIR=/etc/ssl/ufla-shop
ORIGEM="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "==> $*"; }

# O psql reclama quando o cwd nao e legivel pelo usuario postgres --- por isso
# toda chamada sai de /.
pg() { (cd / && sudo -u postgres "$@"); }

if [[ $EUID -ne 0 ]]; then
    echo "rode com sudo" >&2
    exit 1
fi

# ---------------------------------------------------------------- pacotes
log "pacotes do sistema"
export DEBIAN_FRONTEND=noninteractive
FALTANDO=()
for pacote in python3-venv postgresql redis-server nginx rsync openssl; do
    dpkg-query -W -f='${Status}' "$pacote" 2>/dev/null | grep -q "^install ok installed" \
        || FALTANDO+=("$pacote")
done
if [[ ${#FALTANDO[@]} -gt 0 ]]; then
    log "instalando: ${FALTANDO[*]}"
    apt-get update -qq
    apt-get install -y -qq "${FALTANDO[@]}"
else
    log "nada a instalar"
fi

systemctl enable --now postgresql redis-server >/dev/null

# ---------------------------------------------------------------- usuario
if id "$USUARIO" &>/dev/null; then
    log "usuario $USUARIO ja existe"
else
    log "criando usuario $USUARIO"
    useradd --system --home-dir "$DESTINO" --shell /usr/sbin/nologin "$USUARIO"
fi

# ------------------------------------------------------------- segredos
install -m 0644 "$ORIGEM/systemd/ufla-shop.env.example" "$ENV_MODELO"
if [[ -f "$ENV_FILE" ]]; then
    log "$ENV_FILE preservado"
else
    log "criando $ENV_FILE a partir do modelo"
    sed "s/TROCAR_SENHA/$(openssl rand -hex 16)/" "$ENV_MODELO" > "$ENV_FILE"
fi
chown root:"$USUARIO" "$ENV_FILE"
chmod 0640 "$ENV_FILE"

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
SENHA="${DATABASE_URL#*//loja:}"
SENHA="${SENHA%%@*}"

# ---------------------------------------------------------------- banco
EXISTE_ROLE=$(pg psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'loja'")
if [[ "$EXISTE_ROLE" == "1" ]]; then
    log "role loja ja existe, sincronizando a senha"
    pg psql -qc "ALTER ROLE loja WITH LOGIN PASSWORD '$SENHA'"
else
    log "criando role loja"
    pg psql -qc "CREATE ROLE loja WITH LOGIN PASSWORD '$SENHA'"
fi

EXISTE_DB=$(pg psql -tAc "SELECT 1 FROM pg_database WHERE datname = 'loja'")
if [[ "$EXISTE_DB" == "1" ]]; then
    log "banco loja ja existe"
else
    log "criando banco loja"
    pg createdb -O loja loja
fi

# ---------------------------------------------------------------- codigo
log "sincronizando o codigo em $DESTINO"
mkdir -p "$DESTINO"
rsync -a --delete \
    --exclude '.git/' --exclude '.venv/' --exclude '__pycache__/' \
    --exclude 'dados/' --exclude '*.db' \
    "$ORIGEM"/app "$ORIGEM"/static "$ORIGEM"/scripts "$ORIGEM"/requirements.txt \
    "$DESTINO/"

if [[ -x "$DESTINO/.venv/bin/python" ]]; then
    log "venv ja existe"
else
    log "criando o venv"
    python3 -m venv "$DESTINO/.venv"
fi
"$DESTINO/.venv/bin/pip" install -q --upgrade pip
"$DESTINO/.venv/bin/pip" install -q -r "$DESTINO/requirements.txt"
chown -R "$USUARIO":"$USUARIO" "$DESTINO"

# ---------------------------------------------------------------- backup
install -d -o "$USUARIO" -g "$USUARIO" -m 0750 /var/backups/ufla-shop

# --------------------------------------------------------------- systemd
log "instalando as units"
install -m 0644 "$ORIGEM"/systemd/ufla-shop.service        /etc/systemd/system/
install -m 0644 "$ORIGEM"/systemd/ufla-shop-backup.service /etc/systemd/system/
install -m 0644 "$ORIGEM"/systemd/ufla-shop-backup.timer   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now ufla-shop-backup.timer >/dev/null
systemctl enable ufla-shop >/dev/null
systemctl restart ufla-shop

# ----------------------------------------------------------------- nginx
if [[ -f "$CERT_DIR/loja.crt" && -f "$CERT_DIR/loja.key" ]]; then
    log "certificado ja existe"
else
    log "gerando certificado autoassinado"
    install -d -m 0755 "$CERT_DIR"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$CERT_DIR/loja.key" -out "$CERT_DIR/loja.crt" \
        -subj "/C=BR/ST=MG/L=Lavras/O=UFLA/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
    chmod 0600 "$CERT_DIR/loja.key"
fi

install -m 0644 "$ORIGEM/nginx/loja.conf" /etc/nginx/sites-available/loja.conf
ln -sfn /etc/nginx/sites-available/loja.conf /etc/nginx/sites-enabled/loja.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# ----------------------------------------------------------- healthcheck
log "healthcheck em /ready"
for tentativa in $(seq 1 10); do
    CODIGO=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/ready || true)
    if [[ "$CODIGO" == "200" ]]; then
        log "pronto na tentativa $tentativa"
        exit 0
    fi
    echo "    tentativa $tentativa: HTTP ${CODIGO:-sem resposta}"
    sleep 1
done

echo "a aplicacao nao respondeu 200 em /ready --- veja: journalctl -u ufla-shop -n 50" >&2
exit 1
