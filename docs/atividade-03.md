# Atividade 3 -- Automatizar de verdade

Lucas Gabriel Pereira Moreira (@lucasgpmoreira)

Máquina usada: Pop!_OS 22.04 (base Ubuntu 22.04), systemd 249, PostgreSQL 14,
Redis 6.0, Nginx 1.18.

Arquivos desta entrega:

```
scripts/deploy.sh              instala tudo e termina com healthcheck em /ready
scripts/backup.sh              pg_dump datado + rotacao de 7
systemd/ufla-shop.service      a API, como usuario ufla-shop
systemd/ufla-shop-backup.service
systemd/ufla-shop-backup.timer todo dia as 03:00, Persistent=true
systemd/ufla-shop.env.example  modelo do EnvironmentFile (sem senha)
nginx/loja.conf                80 -> 301, 443 com TLS -> 127.0.0.1:8000
```

## (a) Como rodar numa máquina limpa

```bash
git clone https://github.com/lucasgpmoreira/ufla-devops-shop.git
cd ufla-devops-shop
git switch atividade-03
sudo ./scripts/deploy.sh
```

Não precisa instalar nada antes nem criar banco na mão. O script, na ordem:

1. instala o que faltar entre `python3-venv postgresql redis-server nginx rsync openssl` (só chama o `apt-get` se faltar algum);
2. cria o usuário de sistema `ufla-shop` se `id ufla-shop` falhar;
3. instala `/etc/ufla-shop.env.example` e, **só se `/etc/ufla-shop.env` não existir**, cria esse arquivo a partir do modelo trocando `TROCAR_SENHA` por `openssl rand -hex 16`. Fica `root:ufla-shop` com modo `0640`;
4. cria a role e o banco `loja` se não existirem (consulta `pg_roles` e `pg_database` antes). A senha da role é sempre sincronizada com a do `.env`, então se alguém editar o arquivo basta rodar o deploy de novo;
5. `rsync` do código para `/opt/ufla-shop`, cria o venv se não existir e roda `pip install -r requirements.txt`;
6. instala as três units, `daemon-reload`, habilita o timer e o serviço e faz `restart` na API;
7. gera o certificado autoassinado em `/etc/ssl/ufla-shop/` se ainda não existir, instala o `loja.conf`, desabilita o site `default`, `nginx -t` e `reload`;
8. consulta `http://localhost:8000/ready` até 10 vezes com 1 s de intervalo e sai com `exit 1` se nunca vier 200.

A senha do banco não aparece em nenhum arquivo versionado. O que está no git é
só o modelo com o marcador:

```
DATABASE_URL=postgresql://loja:TROCAR_SENHA@localhost:5432/loja
```

O certificado e a chave ficam em `/etc/ssl/ufla-shop/`, fora do repositório (e
`*.pem`/`*.key` já estão no `.gitignore` de qualquer forma).

## (b) `systemctl status` depois do `kill -9`

O enunciado sugere `kill -9 $(pidof uvicorn)`, mas aqui o `pidof uvicorn` não
acha nada: o `uvicorn` do venv é um script Python, então o nome do processo é
`python3`. Usei o PID que o próprio systemd guarda:

```bash
PID=$(systemctl show -p MainPID --value ufla-shop)
sudo kill -9 $PID
sleep 5
systemctl status ufla-shop --no-pager
```

```
pid antes = 16923
pid depois = 16957
```

```
● ufla-shop.service - ufla-devops-shop --- API da loja
     Loaded: loaded (/etc/systemd/system/ufla-shop.service; enabled; vendor preset: enabled)
     Active: active (running) since Thu 2026-10-01 20:52:41 -03; 2s ago
       Docs: https://github.com/rdurelli/ufla-devops-shop
   Main PID: 16957 (uvicorn)
      Tasks: 1 (limit: 16634)
     Memory: 39.4M
        CPU: 481ms
     CGroup: /system.slice/ufla-shop.service
             └─16957 /opt/ufla-shop/.venv/bin/python3 /opt/ufla-shop/.venv/bin/uvicorn app:api --host 127.0.0.1 --port 8000

Oct 01 20:52:41 pop-os systemd[1]: Starting ufla-devops-shop --- API da loja...
Oct 01 20:52:41 pop-os systemd[1]: Started ufla-devops-shop --- API da loja.
Oct 01 20:52:42 pop-os uvicorn[16957]: INFO:     Started server process [16957]
Oct 01 20:52:42 pop-os uvicorn[16957]: INFO:     Waiting for application startup.
Oct 01 20:52:42 pop-os uvicorn[16957]: 2026-10-01 20:52:42,098 INFO loja: ufla-devops-shop 1.0.0 subindo (banco=postgresql, cache=redis, instancia=pop-os)
Oct 01 20:52:42 pop-os uvicorn[16957]: 2026-10-01 20:52:42,159 INFO loja.banco: banco pronto (modo postgresql)
Oct 01 20:52:42 pop-os uvicorn[16957]: INFO:     Application startup complete.
Oct 01 20:52:42 pop-os uvicorn[16957]: INFO:     Uvicorn running on http://127.0.0.1:8000 (Press CTRL+C to quit)
```

O `status` só mostra o processo novo. O que aconteceu no meio está no journal:

```bash
journalctl -u ufla-shop --since "20:52:39"
```

```
Oct 01 20:52:39 pop-os systemd[1]: ufla-shop.service: Main process exited, code=killed, status=9/KILL
Oct 01 20:52:39 pop-os systemd[1]: ufla-shop.service: Failed with result 'signal'.
Oct 01 20:52:41 pop-os systemd[1]: ufla-shop.service: Scheduled restart job, restart counter is at 1.
Oct 01 20:52:41 pop-os systemd[1]: Stopped ufla-devops-shop --- API da loja.
Oct 01 20:52:41 pop-os systemd[1]: Starting ufla-devops-shop --- API da loja...
Oct 01 20:52:41 pop-os systemd[1]: Started ufla-devops-shop --- API da loja.
```

Morreu com SIGKILL às 20:52:39 e voltou às 20:52:41: são os 2 s do
`RestartSec=2`. O `Restart=on-failure` pega esse caso porque morte por sinal
conta como falha.

O serviço não roda como root:

```bash
ps -o user=,args= -p $(systemctl show -p MainPID --value ufla-shop)
systemctl show -p User -p EnvironmentFiles -p Restart ufla-shop
```

```
ufla-sh+ /opt/ufla-shop/.venv/bin/python3 /opt/ufla-shop/.venv/bin/uvicorn app:api --host 127.0.0.1 --port 8000
```

```
Restart=on-failure
EnvironmentFiles=/etc/ufla-shop.env (ignore_errors=no)
User=ufla-shop
```

## (c) Nginx: `curl -kI https://localhost` e `curl -I http://localhost`

```
$ curl -sI http://localhost
HTTP/1.1 301 Moved Permanently
Server: nginx/1.18.0 (Ubuntu)
Date: Thu, 01 Oct 2026 23:52:44 GMT
Content-Type: text/html
Content-Length: 178
Connection: keep-alive
Location: https://localhost/
```

```
$ curl -skI https://localhost
HTTP/2 405
server: nginx/1.18.0 (Ubuntu)
date: Thu, 01 Oct 2026 23:52:44 GMT
content-type: application/json
content-length: 31
allow: GET
```

O 405 não vem do Nginx, vem da aplicação. O `-I` manda `HEAD`, e a rota `/` em
`app/principal.py` é declarada com `@api.get("/")`, que só aceita `GET` (por
isso o `allow: GET` na resposta). O TLS e o proxy estão funcionando, tanto que
quem respondeu foi o FastAPI. Com `GET`, ou com `HEAD` numa rota que aceita
`HEAD` (o `/static` é montado com `StaticFiles`, que aceita), dá 200 pelo
HTTP/2:

```
$ curl -sk -o /dev/null -w "%{http_code} HTTP/%{http_version}\n" https://localhost
200 HTTP/2
```

```
$ curl -skI https://localhost/static/index.html
HTTP/2 200
server: nginx/1.18.0 (Ubuntu)
date: Thu, 01 Oct 2026 23:52:44 GMT
content-type: text/html; charset=utf-8
content-length: 1262
accept-ranges: bytes
last-modified: Thu, 01 Oct 2026 23:20:16 GMT
etag: "136a425d2e30034f82ecfdef45f7a7e1"
```

```
$ curl -ks https://localhost/ready
{"status":"ok","banco":"ok","cache":"ok"}
```

Não mexi na aplicação para fazer o `HEAD /` dar 200 porque o código dela vem do
repositório da turma.

### Cabeçalhos de IP real

Para ver o que o Nginx realmente manda para a API, parei o serviço, coloquei um
`nc` escutando no lugar dele e fiz uma requisição pelo 443:

```bash
sudo systemctl stop ufla-shop
nc -l 127.0.0.1 8000 &
curl -ks https://localhost/api/info
sudo systemctl start ufla-shop
```

```
GET /api/info HTTP/1.0
Host: localhost
X-Real-IP: 127.0.0.1
X-Forwarded-For: 127.0.0.1
X-Forwarded-Proto: https
Connection: close
user-agent: curl/7.81.0
accept: */*
```

E mandando um `X-Forwarded-For` de fora (`-H 'X-Forwarded-For: 203.0.113.9'`),
dá para ver o `$proxy_add_x_forwarded_for` acrescentando o IP do cliente no fim
da lista em vez de sobrescrever:

```
X-Real-IP: 127.0.0.1
X-Forwarded-For: 203.0.113.9, 127.0.0.1
X-Forwarded-Proto: https
```

A API escuta só no loopback, o que fica exposto é o Nginx:

```
$ ss -ltn | grep -E ':(8000|80|443)\s'
LISTEN 0      2048                     127.0.0.1:8000       0.0.0.0:*
LISTEN 0      511                        0.0.0.0:443        0.0.0.0:*
LISTEN 0      511                        0.0.0.0:80         0.0.0.0:*
LISTEN 0      511                           [::]:443           [::]:*
LISTEN 0      511                           [::]:80            [::]:*
```

## (d) `ls -la /var/backups/ufla-shop`

Como o nome do arquivo vai até o minuto (`loja-AAAA-MM-DD-HHMM.sql.gz`), duas
execuções no mesmo minuto geram o mesmo nome. Por isso rodei o backup com 61 s
de intervalo. E em vez de parar em 3, fui até 9, para ver a rotação cortar no
sétimo. Cada execução foi pelo próprio serviço, não chamando o script direto:

```bash
for i in $(seq 1 9); do
    sudo systemctl start --wait ufla-shop-backup.service
    ls -1 /var/backups/ufla-shop | wc -l
    sleep 61
done
```

Quantidade de arquivos depois de cada execução (todas com status 0):

```
execucao 1: 1
execucao 2: 2
execucao 3: 3
execucao 4: 4
execucao 5: 5
execucao 6: 6
execucao 7: 7
execucao 8: 7
execucao 9: 7
```

O `ls -la` no fim:

```
total 36
drwxr-x--- 2 ufla-shop ufla-shop 4096 Oct  1 20:37 .
drwxr-xr-x 3 root      root      4096 Oct  1 20:29 ..
-rw-r--r-- 1 ufla-shop ufla-shop 1591 Oct  1 20:31 loja-2026-10-01-2031.sql.gz
-rw-r--r-- 1 ufla-shop ufla-shop 1591 Oct  1 20:32 loja-2026-10-01-2032.sql.gz
-rw-r--r-- 1 ufla-shop ufla-shop 1589 Oct  1 20:33 loja-2026-10-01-2033.sql.gz
-rw-r--r-- 1 ufla-shop ufla-shop 1587 Oct  1 20:34 loja-2026-10-01-2034.sql.gz
-rw-r--r-- 1 ufla-shop ufla-shop 1590 Oct  1 20:35 loja-2026-10-01-2035.sql.gz
-rw-r--r-- 1 ufla-shop ufla-shop 1588 Oct  1 20:36 loja-2026-10-01-2036.sql.gz
-rw-r--r-- 1 ufla-shop ufla-shop 1587 Oct  1 20:37 loja-2026-10-01-2037.sql.gz
```

Os dumps de 20:29 e 20:30 foram apagados. O registro no journal (`logger -t backup`):

```bash
journalctl -t backup --no-pager
```

```
Oct 01 20:29:15 pop-os backup[15402]: falha no pg_dump do banco loja
Oct 01 20:29:16 pop-os backup[15417]: gerado /var/backups/ufla-shop/loja-2026-10-01-2029.sql.gz (4.0K)
Oct 01 20:30:17 pop-os backup[15457]: gerado /var/backups/ufla-shop/loja-2026-10-01-2030.sql.gz (4.0K)
Oct 01 20:31:18 pop-os backup[15503]: gerado /var/backups/ufla-shop/loja-2026-10-01-2031.sql.gz (4.0K)
Oct 01 20:32:19 pop-os backup[15543]: gerado /var/backups/ufla-shop/loja-2026-10-01-2032.sql.gz (4.0K)
Oct 01 20:33:20 pop-os backup[15586]: gerado /var/backups/ufla-shop/loja-2026-10-01-2033.sql.gz (4.0K)
Oct 01 20:34:21 pop-os backup[15622]: gerado /var/backups/ufla-shop/loja-2026-10-01-2034.sql.gz (4.0K)
Oct 01 20:35:23 pop-os backup[15672]: gerado /var/backups/ufla-shop/loja-2026-10-01-2035.sql.gz (4.0K)
Oct 01 20:36:24 pop-os backup[15706]: gerado /var/backups/ufla-shop/loja-2026-10-01-2036.sql.gz (4.0K)
Oct 01 20:36:24 pop-os backup[15711]: rotacao: 1 dump(s) antigo(s) apagado(s)
Oct 01 20:37:25 pop-os backup[15744]: gerado /var/backups/ufla-shop/loja-2026-10-01-2037.sql.gz (4.0K)
Oct 01 20:37:25 pop-os backup[15749]: rotacao: 1 dump(s) antigo(s) apagado(s)
```

O tamanho no log é o do `du -h` (4.0K, um bloco); o arquivo tem ~1,6 KB.

A primeira linha (`falha no pg_dump`) foi proposital: rodei o backup com a
senha errada para conferir o código de saída.

```bash
sudo -u ufla-shop env DATABASE_URL=postgresql://loja:senha-errada@localhost:5432/loja \
    /opt/ufla-shop/scripts/backup.sh
echo $?
```

```
pg_dump: error: connection to server at "localhost" (::1), port 5432 failed: FATAL:  password authentication failed for user "loja"
pg_dump falhou
1
```

Sem o `pipefail`, esse `pg_dump | gzip` sairia com 0, porque quem decide o
status do pipe é o último comando, e o `gzip` comprime a entrada vazia sem
reclamar. Ainda por cima ficaria um `.sql.gz` de 20 bytes na pasta, contando
como um dos 7. Por isso o dump é escrito primeiro em `.parcial` e só é renomeado
se o pipe inteiro der certo.

O timer:

```
$ systemctl list-timers ufla-shop-backup.timer
NEXT                        LEFT    LAST PASSED UNIT                   ACTIVATES
Fri 2026-10-02 03:00:00 -03 6h left n/a  n/a    ufla-shop-backup.timer ufla-shop-backup.service

1 timers listed.
```

```
$ systemctl is-enabled ufla-shop ufla-shop-backup.timer
enabled
enabled
```

## (e) Idempotência: duas execuções seguidas do `deploy.sh`

Primeira execução, na máquina ainda sem Redis, sem usuário, sem banco e sem
certificado (cortei a saída do `apt-get`):

```
==> pacotes do sistema
==> instalando: redis-server
[... saida do apt-get ...]
Synchronizing state of postgresql.service with SysV service script with /lib/systemd/systemd-sysv-install.
Executing: /lib/systemd/systemd-sysv-install enable postgresql
Synchronizing state of redis-server.service with SysV service script with /lib/systemd/systemd-sysv-install.
Executing: /lib/systemd/systemd-sysv-install enable redis-server
==> criando usuario ufla-shop
==> criando /etc/ufla-shop.env a partir do modelo
==> criando role loja
==> criando banco loja
==> sincronizando o codigo em /opt/ufla-shop
==> criando o venv
==> instalando as units
Created symlink /etc/systemd/system/timers.target.wants/ufla-shop-backup.timer → /etc/systemd/system/ufla-shop-backup.timer.
Created symlink /etc/systemd/system/multi-user.target.wants/ufla-shop.service → /etc/systemd/system/ufla-shop.service.
==> gerando certificado autoassinado
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
==> healthcheck em /ready
    tentativa 1: HTTP 000
==> pronto na tentativa 2
status deploy 1 = 0
```

Execução seguinte, logo depois:

```
==> pacotes do sistema
==> nada a instalar
Synchronizing state of postgresql.service with SysV service script with /lib/systemd/systemd-sysv-install.
Executing: /lib/systemd/systemd-sysv-install enable postgresql
Synchronizing state of redis-server.service with SysV service script with /lib/systemd/systemd-sysv-install.
Executing: /lib/systemd/systemd-sysv-install enable redis-server
==> usuario ufla-shop ja existe
==> /etc/ufla-shop.env preservado
==> role loja ja existe, sincronizando a senha
==> banco loja ja existe
==> sincronizando o codigo em /opt/ufla-shop
==> venv ja existe
==> instalando as units
==> certificado ja existe
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
==> healthcheck em /ready
    tentativa 1: HTTP 000
==> pronto na tentativa 2
status deploy 2 = 0
```

Na segunda não aparece nenhum "criando" e o `.env` foi preservado. Se ele fosse
regerado, a senha mudaria a cada deploy. Rodei esse par mais uma vez depois de
uma correção no script (o `psql` reclamava do diretório atual) e as duas
execuções saíram com 0 do mesmo jeito.

Sobre o `tentativa 1: HTTP 000`: o deploy faz `restart` na API e consulta o
`/ready` logo em seguida. O uvicorn leva ~1 s para abrir a porta, então a
primeira consulta não acha ninguém e a segunda já recebe 200. É exatamente o
caso que o laço de 10 tentativas existe para cobrir.

## O que deu errado no caminho

- O `psql` rodado com `sudo -u postgres` a partir de `~/Downloads` imprimia `could not change directory to "/home/lucas/Downloads": Permission denied`. Não quebrava nada, mas sujava a saída. Agora as chamadas passam por uma função que faz `cd /` antes.
- O site `default` do Nginx já ocupava a porta 80. O deploy remove o link em `sites-enabled/default`, senão o 301 dependeria de qual `server` o Nginx escolhesse.
- O Nginx 1.18 do Ubuntu 22.04 ainda não tem a diretiva `http2 on;` (só existe a partir da 1.25.1), então o HTTP/2 vai no `listen 443 ssl http2;`.
