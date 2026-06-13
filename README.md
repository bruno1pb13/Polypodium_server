# Polypodium — servidor de sync

Backend de sincronização para o app Polypodium. Mantém um log append-only de eventos e materializa o estado atual em tabelas `mat_*` via Last-Write-Wins.

## Dependências

| Pacote | Uso |
|---|---|
| Dart ≥ 3.0 | runtime |
| `shelf` + `shelf_router` | servidor HTTP |
| `postgres` ^3.0 | PostgreSQL (driver nativo) |
| `dart_jsonwebtoken` | geração e verificação de JWT |
| `bcrypt` | hash de senhas |
| `uuid` | IDs de dispositivos |

## Configuração

```bash
cp .env.example .env
```

Edite `.env`:

```
DATABASE_URL=postgresql://usuario:senha@host/polypodium
JWT_SECRET=chave-aleatoria-com-pelo-menos-32-caracteres
PORT=8080
APP_ENV=development      # usa SslMode.disable; qualquer outro valor exige SSL
```

## Build e execução

```bash
# Instalar dependências
dart pub get

# Rodar em modo desenvolvimento (lê variáveis do .env)
source .env && dart run bin/server.dart

# Compilar para binário nativo
dart compile exe bin/server.dart -o polypodium_server

# Lint
dart analyze
```

As migrações DDL rodam automaticamente na inicialização (`CREATE TABLE IF NOT EXISTS`). Não há ferramenta de migration separada.

## Fluxo de sincronização

### Autenticação

`POST /api/v1/auth/login` — retorna um JWT que embute `userId` e `deviceId`. Todas as rotas de sync exigem `Authorization: Bearer <token>`.

### Push (`POST /api/v1/sync/push`)

O app envia um array de eventos locais pendentes:

```json
{
  "deviceId": "uuid-do-dispositivo",
  "events": [
    {
      "localQueueId": 42,
      "entityType": "plant",
      "entityId": "uuid-da-entidade",
      "operation": "create",
      "payload": { ... },
      "clientTimestamp": "2026-06-13T10:00:00Z"
    }
  ]
}
```

Para cada evento o servidor:
1. Valida `entityType` (`plant`, `species`, `entry`, `location`, `soil`) e `operation` (`create`, `update`, `delete`).
2. Para operações `update`: verifica conflito — se a entidade não existe na tabela `mat_*` mas há um evento `delete` anterior, o evento é rejeitado e retornado em `conflicts`.
3. Insere o evento em `sync_events` (log imutável).
4. Aplica LWW na tabela `mat_<entityType>`: `INSERT … ON CONFLICT DO UPDATE WHERE EXCLUDED.server_timestamp >= tabela.server_timestamp`. Deletes removem a linha.
5. Adiciona `localQueueId` à lista `accepted`.

Resposta:

```json
{ "accepted": [42], "conflicts": [] }
```

O app marca como processados apenas os IDs em `accepted` e atualiza `syncStatus = synced` nas entidades correspondentes.

### Pull (`GET /api/v1/sync/pull?since=<cursor>&limit=100`)

Retorna eventos de `sync_events` **de outros dispositivos** (`device_id != dispositivo_atual`) com `id > since`, ordenados por `id`:

```json
{
  "events": [ { "id": 7, "entityType": "plant", "operation": "create", "payload": { ... }, ... } ],
  "nextCursor": 7,
  "hasMore": false
}
```

O app aplica cada evento localmente (upsert ou delete na tabela Drift correspondente) e chama o ACK.

### ACK (`POST /api/v1/sync/ack`)

```json
{ "deviceId": "uuid", "cursor": 7 }
```

Atualiza `device_cursors.last_pulled_cursor` via `ON CONFLICT DO UPDATE WHERE EXCLUDED > atual`. Garante que o cursor só avança, nunca recua.

O pull loop repete enquanto `hasMore = true`. Ao final, o cursor local é persistido em `SharedPreferences`.

### Status (`GET /api/v1/sync/status`)

Retorna `pendingEventCount` (eventos no servidor ainda não puxados pelo dispositivo), `lastPulledCursor` e `serverLatestCursor`.
