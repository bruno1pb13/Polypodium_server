# API

Todas as rotas vivem sob `/api/v1`. Requisições e respostas usam JSON (`Content-Type: application/json`), exceto o upload/download de fotos (bytes crus).

## Autenticação

Rotas de sync, fotos e admin exigem `Authorization: Bearer <token>`. O token JWT é obtido no login e embute `userId` e `deviceId`. A conta é reverificada no banco a cada requisição — tokens de contas desativadas ou removidas deixam de valer imediatamente.

As rotas `/auth/*` têm rate limit por IP (padrão 20 requisições / 300 s).

### `GET /auth/status`

Sem autenticação. Diz se o servidor já tem alguma conta — o app usa isso para decidir entre mostrar login ou a criação da primeira conta.

```json
{ "hasUsers": false }
```

### `POST /auth/register`

Cria a **primeira** conta do servidor, que vira admin. Depois disso retorna `403` — contas seguintes são criadas pelo admin (ver [Admin](#admin)).

```json
{
  "email": "voce@exemplo.com",
  "password": "minimo-8-caracteres",
  "registrationToken": "obrigatorio-se-REGISTRATION_TOKEN-estiver-definida"
}
```

Resposta `201`:

```json
{ "token": "…", "userId": "…", "deviceId": "…", "role": "admin" }
```

### `POST /auth/login`

```json
{
  "email": "voce@exemplo.com",
  "password": "…",
  "deviceId": "uuid-opcional-do-dispositivo",
  "deviceName": "Polypodium"
}
```

Se `deviceId` for omitido, o servidor gera um novo. Um `deviceId` já vinculado a outra conta é rejeitado com `403`.

Resposta `200`: mesmo formato do register, com o `role` da conta.

## Sync

O modelo é de **linhas versionadas com last-write-wins** (LWW): cada entidade tem uma linha por `(user_id, entity_id)` com `updatedAt` (hora real da edição), `deletedAt` (tombstone de soft-delete — nada é apagado fisicamente) e `rev` (revisão monotônica atribuída pelo servidor a cada escrita).

Tipos de entidade válidos: `species`, `plant`, `entry`, `location`, `soil`, `bed`.

Formato de uma *change* (usado em `changes` e `receive`):

```json
{
  "entityType": "plant",
  "entityId": "uuid-gerado-no-cliente",
  "payload": { },
  "updatedAt": "2026-07-10T12:00:00.000Z",
  "deletedAt": null,
  "deviceId": "uuid-do-dispositivo",
  "rev": 42
}
```

> O `rev` enviado pelo cliente é ignorado — o servidor sempre atribui o seu próprio na escrita.

### `GET /sync/changes?since=<rev>&limit=<n>`

Pull: retorna as linhas do usuário com `rev > since`, de todos os tipos de entidade, ordenadas por `rev`. `limit` entre 1 e 1000 (padrão 100).

```json
{ "changes": [ … ], "nextCursor": 57, "hasMore": false }
```

O cliente repete enquanto `hasMore = true`, passando `nextCursor` como `since`.

#### Tipos de registro (`X-Polypodium-Entry-Types`)

O payload de uma `entry` traz o tipo do registro em `type`, e versões do app até a v2.7.2 lançam erro ao receber um tipo que não conhecem — inclusive em tombstones — o que travaria o pull desses aparelhos para sempre. Por isso o cliente declara os tipos que entende:

```
X-Polypodium-Entry-Types: irrigation,fertilizer,pruning,observation,height,chlorosis,pest,pesticide,other,history,repotting
```

O servidor só envia as `entry` (vivas ou tombstones) cujo `type` está na lista. Sem o header (ou com ele vazio), o cliente é tratado como legado e recebe apenas os 10 tipos originais: `irrigation`, `fertilizer`, `pruning`, `observation`, `height`, `chlorosis`, `pest`, `pesticide`, `other`, `history`. As demais entidades não são filtradas — clientes antigos ignoram `entityType` desconhecidos.

O filtro é aplicado na própria consulta, então as linhas ocultas não entram nem na página nem no cálculo de `hasMore`: o cursor do cliente (o `rev` da última mudança aplicada, que é igual ao `nextCursor`) sempre avança, e uma janela só de linhas ocultas nunca devolve página vazia com `hasMore = true`. Em contrapartida, uma linha oculta que fique para trás do cursor não é reenviada se o cliente passar a declarar o tipo depois (ex.: ao atualizar o app) — só uma nova edição dela gera um `rev` novo.

### `POST /sync/receive`

Push: o cliente envia suas mudanças locais (máximo 500 por lote). O `deviceId` do corpo precisa bater com o do token.

```json
{ "deviceId": "uuid", "changes": [ … ] }
```

Cada mudança é aplicada via LWW: uma escrita mais antiga que a linha atual simplesmente não tem efeito (sem erro). Resposta:

```json
{ "appliedCount": 3 }
```

### `POST /sync/ack`

Registra o maior `rev` que o dispositivo já puxou. Só avança, nunca recua. Informativo — alimenta o `/sync/status`.

```json
{ "deviceId": "uuid", "cursor": 57 }
```

### `GET /sync/status`

Retorna o estado de sincronização do dispositivo atual (eventos pendentes, cursores).

## Fotos

Chave de foto é um nome de arquivo simples (sem `/` nem `..`); cada usuário tem seu próprio diretório no servidor.

- `PUT /photos/<photoKey>` — corpo são os bytes crus da imagem (limite padrão 15 MB). Resposta: `{ "ok": true, "photoKey": "…" }`.
- `GET /photos/<photoKey>` — devolve os bytes com o `Content-Type` inferido da extensão (jpg, png, webp, gif).

## Admin

Além de `GET /admin/me` (dados da própria conta), as rotas abaixo exigem `role: admin`:

| Rota | Ação |
|---|---|
| `GET /admin/status` | Visão geral do servidor |
| `GET /admin/settings` / `PATCH /admin/settings` | Configurações do servidor |
| `GET /admin/users` | Lista contas |
| `POST /admin/users` | Cria conta (único caminho após a primeira) |
| `PATCH /admin/users/<id>/role` | Promove/rebaixa admin |
| `PATCH /admin/users/<id>/status` | Ativa/desativa conta |

O app Polypodium expõe tudo isso na tela de administração do servidor.

## Saúde

### `GET /health`

Sem autenticação: `{ "status": "ok", "version": "…" }`. Útil para health checks de proxy/monitoramento.
