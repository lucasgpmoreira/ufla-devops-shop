#!/usr/bin/env bash
#
# Dump diario do banco loja, com rotacao: guarda os 7 mais recentes.
# Chamado pelo ufla-shop-backup.service (que e disparado pelo timer).
#
set -euo pipefail

DESTINO=/var/backups/ufla-shop
MANTER=7
ENV_FILE=/etc/ufla-shop.env

# Rodando na mao (sem o EnvironmentFile da unit), le o arquivo direto.
if [[ -z "${DATABASE_URL:-}" && -r "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

if [[ -z "${DATABASE_URL:-}" ]]; then
    logger -t backup -p user.err "DATABASE_URL nao definida"
    echo "DATABASE_URL nao definida" >&2
    exit 1
fi

mkdir -p "$DESTINO"
ARQUIVO="$DESTINO/loja-$(date +%Y-%m-%d-%H%M).sql.gz"
PARCIAL="$ARQUIVO.parcial"

# O pipefail e o que faz esta linha falhar quando o pg_dump falha --- sem ele
# o status seria o do gzip, que termina feliz com a entrada vazia.
if ! pg_dump --no-owner "$DATABASE_URL" | gzip -9 > "$PARCIAL"; then
    rm -f "$PARCIAL"
    logger -t backup -p user.err "falha no pg_dump do banco loja"
    echo "pg_dump falhou" >&2
    exit 1
fi
mv "$PARCIAL" "$ARQUIVO"

TAMANHO=$(du -h "$ARQUIVO" | cut -f1)
logger -t backup "gerado $ARQUIVO ($TAMANHO)"

# Rotacao: do mais novo para o mais velho, apaga do 8o em diante.
mapfile -t VELHOS < <(ls -1t "$DESTINO"/loja-*.sql.gz | tail -n "+$((MANTER + 1))")
if [[ ${#VELHOS[@]} -gt 0 ]]; then
    rm -f -- "${VELHOS[@]}"
    logger -t backup "rotacao: ${#VELHOS[@]} dump(s) antigo(s) apagado(s)"
fi

echo "$ARQUIVO ($TAMANHO)"
