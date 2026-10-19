# Atividade 4 - Containerizar a aplicação

Imagem final: `ufla-shop:1.0`. Build multi-stage com `python:3.12-alpine` no
estágio final, roda com o usuário `loja` (UID 10001), tem `HEALTHCHECK` no
`/health` e o `CMD` está na forma exec.

## 1. Antes e depois

A primeira versão que funcionou eu marquei como `ufla-shop:0.1`. Era o básico:
um estágio só em cima do `python:3.12-slim`, `pip install -r requirements.txt`
e `COPY . .`, ainda sem `.dockerignore`.

```
$ docker images ufla-shop
REPOSITORY   TAG       IMAGE ID       CREATED          SIZE
ufla-shop    1.0       3818bf4354a5   3 seconds ago    126MB
ufla-shop    0.1       9ef30d6d2f5e   2 weeks ago      463MB

$ docker image inspect --format '{{.Size}}' ufla-shop:0.1 | numfmt --to=si
98M
$ docker image inspect --format '{{.Size}}' ufla-shop:1.0 | numfmt --to=si
30M
```

| Versão | Soma das camadas (`docker history`) | `docker images` |
|--------|-------------------------------------|-----------------|
| 0.1    | 366 MB                              | 463 MB          |
| 1.0    | 97 MB                               | 126 MB          |

Os números não batem entre um comando e outro, e eu demorei um pouco pra
entender o motivo. Aqui uso o Docker Desktop com o image store do containerd.
Nesse modo o `docker images` mostra as camadas descompactadas somadas com os
blobs compactados (97 + 30 ≈ 126), e o `docker image inspect .Size` mostra só o
tamanho compactado. O que dá pra comparar com a tabela do `docs/aplicacao.md`
é a soma das camadas do `docker history`, então considerei 97 MB. De qualquer
jeito, nas três medidas a imagem fica abaixo de 150 MB.

## 2. O que mudou e quanto cada mudança economizou

Fui fazendo uma mudança de cada vez e gerando uma tag pra cada passo, pra
conseguir medir separado. Tamanho = soma das camadas no `docker history`.

| Versão | Mudança                                                     | Tamanho | Economia |
|--------|-------------------------------------------------------------|---------|----------|
| 0.1    | slim, um estágio, `COPY . .`                                | 366 MB  | -        |
| 0.2    | adicionei o `.dockerignore`                                 | 204 MB  | 162 MB   |
| 0.3    | multi-stage com venv sem pip, sem cache e sem `__pycache__`, copiando só `app/` e `static/` | 170 MB | 34 MB |
| 1.0    | troquei o estágio final para `python:3.12-alpine`           | 97 MB   | 73 MB    |

O que deu pra ver no `docker history` em cada passo:

**`.dockerignore`.** Na 0.1 a camada do `COPY . .` sozinha tinha 154 MB, porque
ia junto o `.venv` local, o `.git`, a pasta `dados/`, os testes e o `loja.db`.
Depois do `.dockerignore` essa camada caiu pra uns 70 kB. Fora o tamanho, isso
é o que mais importa do lado de segurança, já que `.git` e `.env` não podem
estar na imagem.

**Multi-stage.** Na 0.2 o `pip install` gerava uma camada de 69 MB. Agora as
dependências são instaladas num venv em `/opt/venv` no estágio `build` e o
estágio final só copia esse venv (35,5 MB no slim, 33,7 MB no alpine). O que
ficou de fora:

- pip e setuptools dentro do venv. Criei o venv com `--without-pip` e uso o pip
  do próprio estágio de build pra instalar nele (`pip --python /opt/venv/bin/python`);
- cache de download do pip (`--no-cache-dir`);
- os `.pyc`, com `--no-compile` e um `find` apagando os `__pycache__`. Com
  `PYTHONDONTWRITEBYTECODE=1` eles também não são criados quando a aplicação
  roda (e o usuário `loja` nem teria permissão de escrever em `/opt/venv`);
- tudo que não precisa pra rodar. Troquei o `COPY . .` por `COPY app/` e
  `COPY static/`, então `requirements-dev.txt`, `pyproject.toml`, `scripts/`,
  `docs/` etc. não entram.

**Alpine.** Depois do multi-stage, quase tudo que sobrava era a própria imagem
base: o `python:3.12-slim` dá uns 135 MB e o `python:3.12-alpine` uns 63 MB.
Como todas as dependências têm wheel `musllinux` (inclusive o
`psycopg[binary]`), nada precisa ser compilado e não precisei instalar `gcc` no
build. Só com slim + multi-stage eu parava em 170 MB, então a troca de base foi
o que fez bater a meta.

Camadas da imagem final:

```
$ docker history ufla-shop:1.0 --format '{{.Size}}\t{{.CreatedBy}}' | head -11
0B      CMD ["uvicorn" "app:api" "--host" "0.0.0.0" …
0B      HEALTHCHECK {Test:[CMD python -c import urll…
0B      EXPOSE [8000/tcp]
0B      USER loja
24.6kB  COPY static/ ./static/ # buildkit
53.2kB  COPY app/ ./app/ # buildkit
33.7MB  COPY /opt/venv /opt/venv # buildkit
8.19kB  WORKDIR /app
36.9kB  RUN /bin/sh -c addgroup -S -g 10001 loja    …
0B      ENV PATH=/opt/venv/bin:/usr/local/bin:/usr/l…
0B      CMD ["python3"]
```

Outras escolhas no `Dockerfile`:

- Usuário `loja` (UID/GID 10001), sem home e sem shell de login. O código em
  `/app` fica com o root, então a aplicação só lê.
- O SQLite grava em `/dados/loja.db` (`SQLITE_PATH`). Criei esse diretório e dei
  `chown` pro `loja`, é o único lugar onde ele escreve. Isso resolve o
  "Permission denied em loja.db" e na próxima atividade dá pra virar volume.
- O `HEALTHCHECK` usa o próprio Python (`urllib.request`) batendo em
  `http://127.0.0.1:8000/health`. O alpine não tem curl e não valia a pena
  instalar só pra isso.
- `CMD` na forma exec, então o `uvicorn` é o PID 1 e recebe o `SIGTERM` do
  `docker stop` direto.

## 3. Verificação

Obs.: aqui a porta 8000 já está ocupada pelo `ufla-shop.service` da Atividade 3
(systemd em `127.0.0.1:8000`), por isso publiquei em `8080:8000`. O resto é
igual ao enunciado.

```
$ docker build -t ufla-shop:1.0 .
$ docker image inspect --format '{{.Size}}' ufla-shop:1.0 | numfmt --to=si
30M
$ docker run -d --name loja -p 8080:8000 ufla-shop:1.0
b7ffd20be9029000932bbcc84d0c4c0afd6028e2819b477f7cc847adf5b1f680
$ docker run --rm ufla-shop:1.0 id -u
10001
$ sleep 10 && docker inspect --format '{{.State.Health.Status}}' loja
healthy
$ curl -s localhost:8080/health && curl -s localhost:8080/api/produtos | head -c 200
{"status":"ok","versao":"1.0.0"}[{"id":1,"nome":"Caneca DevOps na Prática","descricao":"Cerâmica, 350 ml: 'funciona na minha máquina'","preco":39.9,"estoque":25,"criado_em":"2026-10-19 22:01:38"},{"id":2,"nome":"Camiseta UFLA Com
$ curl -s localhost:8080/api/produtos | python3 -c 'import json,sys;print(len(json.load(sys.stdin)), "produtos")'
12 produtos
$ docker exec loja sh -c 'ps -o pid,user,args | head -2; ls -l /dados'
PID   USER     COMMAND
    1 loja     {uvicorn} /opt/venv/bin/python /opt/venv/bin/uvicorn app:api --host 0.0.0.0 --port 8000
total 16
-rw-r--r--    1 loja     loja         16384 Oct 19 22:01 loja.db
$ time docker stop loja
loja

real	0m0.424s
user	0m0.008s
sys	0m0.014s
$ docker logs loja 2>&1 | tail -4
INFO:     Waiting for application shutdown.
2026-10-19 22:01:46,509 INFO loja: ufla-devops-shop encerrando
INFO:     Application shutdown complete.
INFO:     Finished server process [1]
$ docker run --rm ufla-shop:1.0 ls -a /app
.
..
app
static
```

O `uvicorn` aparece como PID 1 e o log termina com `Application shutdown
complete`, ou seja, o `SIGTERM` chegou na aplicação e ela encerrou normalmente
em 0,42 s, sem precisar esperar os 10 s até o `SIGKILL`.

## 4. Por que o `HEALTHCHECK` consulta `/health` e não `/ready`?

O `/health` é o teste de liveness: só diz se o processo está vivo, sem
depender de banco nem de cache, e é isso que o `HEALTHCHECK` quer saber, porque
`unhealthy` significa que aquele container está quebrado e precisa ser
reiniciado. Já o `/ready` depende do PostgreSQL e do Redis, então se o banco
caísse todos os containers ficariam `unhealthy` e seriam reiniciados sem
motivo (reiniciar a API não conserta o banco); o papel dele é tirar a instância
do tráfego, não matar o container.
