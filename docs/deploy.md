# Instalação e operação

Guia completo para hospedar o seu próprio servidor Polypodium com Docker.

## O que você vai precisar

- Uma máquina que fique ligada quando você quiser sincronizar: VPS, mini-PC, NAS ou um computador na rede local.
- [Docker](https://docs.docker.com/engine/install/) com o plugin Docker Compose.
- Opcional, recomendado para acesso pela internet: um domínio apontando para a máquina, para HTTPS com Let's Encrypt.

Não é preciso clonar este repositório nem instalar Dart — o servidor é distribuído como imagem pronta em `ghcr.io/bruno1pb13/polypodium_server`.

## 1. Criar os arquivos de configuração

Crie uma pasta (ex.: `polypodium-server`) com um `docker-compose.yml`:

```yaml
services:
  db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: polypodium
      POSTGRES_USER: polypodium
      POSTGRES_PASSWORD: ${DB_PASSWORD:?DB_PASSWORD is required}
    volumes:
      - db_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U polypodium -d polypodium"]
      interval: 5s
      timeout: 5s
      retries: 10

  server:
    image: ghcr.io/bruno1pb13/polypodium_server:latest
    restart: unless-stopped
    ports:
      - "8080:8080"
    environment:
      DATABASE_URL: postgresql://polypodium:${DB_PASSWORD}@db/polypodium
      JWT_SECRET: ${JWT_SECRET:?JWT_SECRET is required}
      APP_ENV: production
      DB_SSL: "false"
      # O HTTPS fica a cargo do proxy reverso (seção 3).
      BEHIND_PROXY: "true"
      REGISTRATION_TOKEN: ${REGISTRATION_TOKEN:-}
      PHOTOS_DIR: /photos
    volumes:
      - photos_data:/photos
    depends_on:
      db:
        condition: service_healthy

volumes:
  db_data:
  photos_data:
```

E um `.env` na mesma pasta:

```bash
# Senha do banco (usada só internamente, entre os contêineres)
DB_PASSWORD=troque-por-uma-senha-forte

# Chave que assina os tokens de login. Mínimo de 32 caracteres.
# Gere uma com:  openssl rand -base64 48
JWT_SECRET=troque-por-uma-chave-aleatoria-bem-longa

# Opcional, recomendado com o servidor exposto na internet:
# protege a criação da primeira conta (seção 4).
REGISTRATION_TOKEN=
```

> **Importante:** o servidor se recusa a iniciar em produção se `JWT_SECRET` estiver ausente ou tiver menos de 32 caracteres. Guarde o `.env` em local seguro.

## 2. Subir o servidor

```bash
docker compose up -d
curl http://localhost:8080/api/v1/health
```

Na primeira execução as tabelas do banco são criadas automaticamente. Logs: `docker compose logs -f server`.

> **Só na rede local?** Se o servidor só será acessado dentro da sua rede (ex.: `http://192.168.0.10:8080`), pule direto para a seção 4. O HTTPS é essencial quando o servidor fica acessível pela internet.

## 3. HTTPS com proxy reverso (Let's Encrypt)

A configuração acima (`BEHIND_PROXY: "true"`) espera um proxy reverso na frente cuidando do HTTPS. A forma mais simples é o [Caddy](https://caddyserver.com/), que obtém e renova certificados Let's Encrypt sozinho. Com o domínio apontando para a máquina, use um `Caddyfile` de duas linhas:

```
plantas.seudominio.com {
    reverse_proxy 127.0.0.1:8080
}
```

Alternativas com o mesmo `BEHIND_PROXY=true`: [Nginx Proxy Manager](https://nginxproxymanager.com/) (interface gráfica), Nginx, Traefik ou Cloudflare Tunnel.

Nesse arranjo, deixe a porta 8080 fechada para a internet no firewall — só o proxy (80/443) fica exposto.

### Alternativa: o próprio servidor termina o HTTPS

Sem proxy, o servidor pode servir HTTPS diretamente. No `docker-compose.yml`, troque `BEHIND_PROXY: "true"` por:

```yaml
      BEHIND_PROXY: "false"
      SSL_CERT_PATH: /certs/fullchain.pem
      SSL_KEY_PATH: /certs/privkey.pem
```

e monte a pasta dos certificados em `volumes:` do serviço `server`:

```yaml
      - /caminho/para/seus/certs:/certs:ro
```

A renovação dos certificados (ex.: `certbot`) fica por sua conta. Em produção o servidor exige uma das duas opções — proxy ou certificados — e se recusa a iniciar servindo HTTP puro.

## 4. Criar a primeira conta (administrador)

A primeira conta criada em um servidor novo vira automaticamente **admin**. Depois dela o cadastro público se fecha: novas contas só podem ser criadas pelo admin, dentro do app.

**Sem `REGISTRATION_TOKEN`** (rede local): no app, abra **Configurações → Servidor**, adicione um workspace remoto com a URL do servidor. O app detecta que ainda não há contas e oferece a criação da primeira — e-mail e senha (mínimo 8 caracteres).

**Com `REGISTRATION_TOKEN`** (recomendado na internet): a primeira conta precisa apresentar o token — assim ninguém "rouba" o posto de admin chegando primeiro. O app não envia esse token, então crie a conta direto pela API:

```bash
curl -X POST https://plantas.seudominio.com/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{
    "email": "voce@exemplo.com",
    "password": "sua-senha-com-8+-caracteres",
    "registrationToken": "o-valor-do-seu-REGISTRATION_TOKEN"
  }'
```

Depois faça login normalmente pelo app. As próximas contas você cria pela tela de administração, dentro do próprio app.

## 5. Backups

Os dados vivem em dois lugares: o banco PostgreSQL e o volume de fotos.

```bash
# Banco de dados
docker compose exec db pg_dump -U polypodium -d polypodium \
  > backup-polypodium-$(date +%F).sql

# Fotos
docker compose cp server:/photos ./backup-fotos-$(date +%F)
```

Restauração (em um banco recém-criado, ainda vazio):

```bash
docker compose exec -T db psql -U polypodium -d polypodium \
  < backup-polypodium-2026-07-10.sql
```

Automatize com um `cron` e guarde as cópias em outra máquina — backup no mesmo disco não protege contra a falha desse disco.

## Atualização

```bash
docker compose pull
docker compose up -d
```

As migrações do banco rodam automaticamente na inicialização.

> **Faça um backup antes de atualizar** (seção 5). Algumas versões reorganizam dados existentes ao subir — e o banco migrado não volta a funcionar com a versão anterior do servidor.

### Atualizando para a versão com jardins compartilhados

Esta versão passa a guardar os dados por **jardim** (para que várias contas compartilhem as mesmas plantas) em vez de por conta. Na primeira inicialização o servidor, sozinho:

- cria um *jardim pessoal* para cada conta e move para ele todos os dados dela — revisões, datas e exclusões preservadas, então os aparelhos não baixam nada de novo;
- mantém as fotos onde estão (o jardim pessoal usa o mesmo diretório da conta).

Tudo roda em uma única transação: se algo falhar, o banco fica exatamente como estava e o servidor não sobe (veja `docker compose logs server`). Em bancos grandes a primeira inicialização pode levar alguns segundos a mais, pois as tabelas são reescritas. Versões antigas do app continuam funcionando sem mudança — sincronizam o jardim pessoal. **Não é possível voltar** para a versão anterior do servidor com o banco migrado; para isso, restaure o backup.

## Referência: variáveis de ambiente

| Variável | Para que serve |
|---|---|
| `DATABASE_URL` | String de conexão do PostgreSQL (obrigatória). |
| `JWT_SECRET` | Assina os tokens de login. Obrigatória, mínimo 32 caracteres, única por servidor. |
| `APP_ENV` | `development` desabilita SSL na conexão com o banco; qualquer outro valor ativa as exigências de produção. |
| `DB_SSL` | SSL na conexão com o banco. `false` quando banco e servidor estão na mesma rede privada (Compose). |
| `REGISTRATION_TOKEN` | Opcional. Quando definida, a criação da primeira conta exige esse token. |
| `BEHIND_PROXY` | `true` quando o HTTPS termina em um proxy reverso; trusts `X-Forwarded-For` para o IP do cliente. |
| `SSL_CERT_PATH` / `SSL_KEY_PATH` | Certificado e chave para o servidor servir HTTPS diretamente. |
| `PORT` | Porta HTTP (padrão 8080). |
| `PHOTOS_DIR` | Diretório de armazenamento das fotos. |
| `ALLOWED_ORIGINS` | CORS: `*` ou lista de origens separadas por vírgula (padrão `*`). |
| `AUTH_RATE_LIMIT_MAX` / `AUTH_RATE_LIMIT_WINDOW` | Limite contra força bruta em `/api/v1/auth/*` (padrão 20 req / 300 s por IP). |
| `MAX_JSON_BODY_BYTES` / `MAX_PHOTO_BYTES` | Tamanho máximo de requisições JSON e fotos (padrão 1 MB / 15 MB). |
