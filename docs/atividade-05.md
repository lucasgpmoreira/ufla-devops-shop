# Atividade 5 - A stack completa

A aplicação agora roda no modo completo, com quatro containers subindo juntos
pelo `compose.yaml`:

- `banco`: `postgres:16-alpine`, com os dados no volume nomeado `dados-banco` e
  healthcheck com `pg_isready`;
- `cache`: `redis:7-alpine`, healthcheck com `redis-cli ping`;
- `api`: a imagem da Atividade 4 publicada no GHCR
  (`ghcr.io/lucasgpmoreira/ufla-shop:1.0.0`), sem porta publicada e esperando
  banco e cache ficarem `healthy` antes de subir;
- `nginx`: `nginx:1.27-alpine` com o `nginx/default.conf` montado, fazendo
  `proxy_pass` para `api:8000`. É o único serviço com porta publicada (80:80).

A senha do banco só existe no `.env` (que não vai pro git). No compose ela
aparece como `${POSTGRES_PASSWORD:?defina no .env}`, tanto no `banco` quanto
na `DATABASE_URL` da api. Sem o `.env` o compose nem sobe:

```
$ docker compose config -q
error while interpolating services.banco.environment.POSTGRES_PASSWORD: required variable POSTGRES_PASSWORD is missing a value: defina no .env
```

## a) `docker compose ps` com tudo healthy

```
$ docker compose up -d --wait
 api Pulling
 api Pulled
 Container ufla-devops-shop-banco-1  Healthy
 Container ufla-devops-shop-cache-1  Healthy
 Container ufla-devops-shop-api-1  Healthy
 Container ufla-devops-shop-nginx-1  Healthy
$ docker compose ps
NAME                       IMAGE                                    COMMAND                  SERVICE   CREATED          STATUS                    PORTS
ufla-devops-shop-api-1     ghcr.io/lucasgpmoreira/ufla-shop:1.0.0   "uvicorn app:api --h…"   api       24 seconds ago   Up 17 seconds (healthy)   8000/tcp
ufla-devops-shop-banco-1   postgres:16-alpine                       "docker-entrypoint.s…"   banco     25 seconds ago   Up 22 seconds (healthy)   5432/tcp
ufla-devops-shop-cache-1   redis:7-alpine                           "docker-entrypoint.s…"   cache     25 seconds ago   Up 22 seconds (healthy)   6379/tcp
ufla-devops-shop-nginx-1   nginx:1.27-alpine                        "/docker-entrypoint.…"   nginx     24 seconds ago   Up 10 seconds (healthy)   0.0.0.0:80->80/tcp
$ curl -I http://localhost
HTTP/1.1 200 OK
Server: nginx/1.27.5
Date: Mon, 19 Oct 2026 22:27:38 GMT
Content-Type: text/html; charset=utf-8
Content-Length: 1262
Connection: keep-alive
$ curl -s http://localhost/api/info
{"aplicacao":"ufla-devops-shop","versao":"1.0.0","banco":"postgresql","cache":"redis","instancia":"f223c357d733"}
$ curl -s http://localhost/ready
{"status":"ok","banco":"ok","cache":"ok"}
```

Antes dessa execução apaguei a imagem local (`docker rmi`), então o `api Pulling`
ali em cima é o compose baixando a imagem do GHCR sem login nenhum, igual vai
acontecer na correção.

Também coloquei um healthcheck no nginx (um `wget` em `/health` passando pelo
proxy), pra ele aparecer como `healthy` e o `--wait` só liberar quando a stack
inteira estiver respondendo.

Um problema que apareceu: o `curl -I` faz uma requisição HEAD, e as rotas do
FastAPI só aceitam GET, então a api devolvia `405 Method Not Allowed`. Em vez de
mexer no código da aplicação, resolvi no nginx: um `map` troca HEAD por GET no
`proxy_method`, e o próprio nginx descarta o corpo na resposta pro cliente. Com
isso o `curl -I` passou a dar 200, e POST/GET continuam iguais.

## b) Roteiro de persistência

```
$ curl -s -X POST http://localhost/api/produtos -H 'Content-Type: application/json' \
     -d '{"nome":"Prova de persistencia","preco":9.9,"estoque":1}'
{"id":13,"nome":"Prova de persistencia","descricao":"","preco":9.9,"estoque":1,"criado_em":"2026-10-19T22:27:43.358184+00:00"}

$ docker compose down
 Container ufla-devops-shop-nginx-1  Removed
 Container ufla-devops-shop-api-1  Removed
 Container ufla-devops-shop-cache-1  Removed
 Container ufla-devops-shop-banco-1  Removed
 Network ufla-devops-shop_default  Removed

$ docker volume ls
DRIVER    VOLUME NAME
local     ufla-devops-shop_dados-banco

$ docker compose up -d --wait
 Container ufla-devops-shop-api-1  Healthy
 Container ufla-devops-shop-banco-1  Healthy
 Container ufla-devops-shop-cache-1  Healthy
 Container ufla-devops-shop-nginx-1  Healthy

$ curl -s 'http://localhost/api/busca?q=persistencia'
{"termo":"persistencia","total":1,"resultados":[{"id":13,"nome":"Prova de persistencia","descricao":"","preco":9.9,"estoque":1,"criado_em":"2026-10-19T22:27:43.358184+00:00"}]}
```

Os containers foram todos removidos no `down`, mas o volume
`ufla-devops-shop_dados-banco` continuou lá (só o `down -v` apaga ele), e o
produto voltou com o mesmo id depois do `up`.

## c) Imagem no GHCR

`ghcr.io/lucasgpmoreira/ufla-shop:1.0.0` (pública)

Página do pacote: https://github.com/users/lucasgpmoreira/packages/container/package/ufla-shop

```
$ docker build -t ghcr.io/lucasgpmoreira/ufla-shop:1.0.0 .
$ docker push ghcr.io/lucasgpmoreira/ufla-shop:1.0.0
...
1.0.0: digest: sha256:57c48b0955021ff963a34c179f152aaeb8125805324de9ff9c26fb3acb1d6537 size: 856
```

A imagem foi construída a partir do `Dockerfile` da Atividade 4. No compose a
api usa a tag `1.0.0` fixa, nada de `latest`.

Obs.: no Linux o Docker Desktop tenta salvar a senha no `pass`, que não estava
configurado aqui, e o `docker login` falhava com `pass not initialized`. Fiz o
login com um `DOCKER_CONFIG` temporário só pro push e apaguei a pasta logo
depois, então o token não ficou salvo em lugar nenhum.

## d) Por que `depends_on` sozinho não resolve a ordem de subida?

Sozinho, o `depends_on` só garante que o container do banco seja *iniciado*
antes do da api, mas o PostgreSQL ainda leva alguns segundos pra aceitar
conexão depois que o container começa, e nesse intervalo a api tenta conectar
e toma `connection refused`. Com `condition: service_healthy` o compose espera
o healthcheck do banco (`pg_isready`) e do cache (`redis-cli ping`) passar antes
de criar a api, ou seja, ela só sobe quando as dependências estão de fato
prontas pra responder.
