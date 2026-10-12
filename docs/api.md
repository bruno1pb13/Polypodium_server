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

O modelo é de **linhas versionadas com last-write-wins** (LWW): cada entidade tem uma linha por `(jardim, entity_id)` com `updatedAt` (hora real da edição), `deletedAt` (tombstone de soft-delete — nada é apagado fisicamente) e `rev` (revisão monotônica atribuída pelo servidor a cada escrita).

### Jardim (`X-Polypodium-Garden`)

Os dados (e as fotos) pertencem a um **jardim**, não a uma conta: várias contas do servidor podem sincronizar o mesmo jardim (veja [Jardins](#jardins)). Toda rota de sync e de fotos age sobre um jardim só:

```
X-Polypodium-Garden: <id-do-jardim>
```

Sem o header (ou com ele vazio), vale o **jardim pessoal** da conta — que guarda tudo o que a conta sincronizava antes de os jardins existirem. Versões do app anteriores aos jardins, que não mandam o header, continuam funcionando sem mudança. Com um id de jardim do qual a conta não é membro (ou que não existe), a resposta é `403 { "error": "not a member of this garden" }`.

Os conflitos continuam resolvidos por LWW por linha, com desempate pelo `deviceId` — aparelhos de contas diferentes escrevendo no mesmo jardim são tratados como aparelhos da mesma conta. A sequência de `rev` é global; o pull filtra pelo jardim.

Tipos de entidade válidos: `species`, `plant`, `entry`, `entry_photo`, `location`, `soil`, `bed`, `defensivo`, `reminder`. Mudanças de outros tipos são descartadas no `receive`.

`entry_photo` são as fotos de um registro depois da primeira, que continua no payload da `entry` (`photoKey`); o payload traz `entryId`, `position` e o `photoKey` do arquivo. O servidor não as filtra: versões do app até a v2.8 ignoram entidades que não conhecem e seguem mostrando só a primeira foto.

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

### `GET /sync/changes?since=<rev>&limit=<n>[&entities=<tipos>]`

Pull: retorna as linhas do jardim com `rev > since`, de todos os tipos de entidade, ordenadas por `rev`. `limit` entre 1 e 1000 (padrão 100).

```json
{ "changes": [ … ], "nextCursor": 57, "hasMore": false, "supportedEntities": ["bed", "defensivo", "entry", "entry_photo", "location", "plant", "reminder", "soil", "species"] }
```

O cliente repete enquanto `hasMore = true`, passando `nextCursor` como `since`.

`supportedEntities` lista, ordenados, todos os tipos de entidade que este servidor guarda (independente de `entities`). Servidores anteriores a ele não mandam o campo. Com ele o app descobre quando uma atualização do servidor passou a guardar um tipo que antes era descartado no `receive` (veja abaixo).

#### Tipos de registro (`X-Polypodium-Entry-Types`)

O payload de uma `entry` traz o tipo do registro em `type`, e versões do app até a v2.7.2 lançam erro ao receber um tipo que não conhecem — inclusive em tombstones — o que travaria o pull desses aparelhos para sempre. Por isso o cliente declara os tipos que entende:

```
X-Polypodium-Entry-Types: irrigation,fertilizer,pruning,observation,height,chlorosis,pest,pesticide,other,history,repotting
```

O servidor só envia as `entry` (vivas ou tombstones) cujo `type` está na lista. Sem o header (ou com ele vazio), o cliente é tratado como legado e recebe apenas os 10 tipos originais: `irrigation`, `fertilizer`, `pruning`, `observation`, `height`, `chlorosis`, `pest`, `pesticide`, `other`, `history`. As demais entidades não são filtradas — clientes antigos ignoram `entityType` desconhecidos.

O filtro é aplicado na própria consulta, então as linhas ocultas não entram nem na página nem no cálculo de `hasMore`: o cursor do cliente (o `rev` da última mudança aplicada, que é igual ao `nextCursor`) sempre avança, e uma janela só de linhas ocultas nunca devolve página vazia com `hasMore = true`. Em contrapartida, uma linha oculta que fique para trás do cursor não é reenviada se o cliente passar a declarar o tipo depois (ex.: ao atualizar o app) — só uma nova edição dela gera um `rev` novo. O app recupera essas linhas com um pull à parte (veja `entities` abaixo).

#### Restringir o pull a algumas entidades (`entities`)

O parâmetro opcional `entities` (lista separada por vírgulas de `entityType`, ex.: `entities=entry`) limita o pull a essas entidades; sem ele (ou vazio), todas são enviadas, como antes. Combina com `X-Polypodium-Entry-Types` e, como ele, é aplicado na consulta, então `nextCursor`/`hasMore` continuam valendo. Nomes desconhecidos são ignorados.

Quando o parâmetro é usado, a resposta o ecoa ordenado — `{ "changes": [ … ], "nextCursor": 57, "hasMore": false, "entities": ["entry"] }` — para o cliente distinguir um servidor anterior a ele, que teria ignorado a restrição e mandado tudo. O eco traz só os tipos que o servidor guarda, então o cliente também sabe quais ele ainda não conhece.

O app usa isso para recuperar os registros que ficaram para trás do cursor enquanto o tipo era oculto: ao passar a entender tipos novos, ele faz um pull à parte desde `since=0` com `entities=entry` e só os tipos novos no header, com cursor próprio. Do mesmo jeito, ao passar a aplicar uma entidade que a versão anterior ignorava (ex.: `entry_photo`), faz uma vez um pull desde `since=0` com `entities=entry_photo`.

### `POST /sync/receive`

Push: o cliente envia suas mudanças locais (máximo 500 por lote). O `deviceId` do corpo precisa bater com o do token.

```json
{ "deviceId": "uuid", "changes": [ … ] }
```

Cada mudança é aplicada via LWW: uma escrita mais antiga que a linha atual simplesmente não tem efeito (sem erro). Mudanças de tipos que o servidor não guarda são descartadas, e a resposta lista esses tipos (ordenados; vazia quando não houve nenhum):

```json
{ "appliedCount": 3, "ignoredEntityTypes": ["hologram"] }
```

Servidores anteriores a `ignoredEntityTypes` (e a `supportedEntities` no pull) descartavam esses tipos em silêncio, e o cursor de push do app já tinha passado por eles. Por isso o app guarda, por servidor, os tipos que este confirmou guardar; quando `supportedEntities` passa a incluir um tipo ainda não confirmado, ele reenvia uma vez todas as linhas locais desse tipo (vivas e tombstones, com o `updatedAt`/`deviceId` atuais — o LWW torna o reenvio idempotente). Os tipos do primeiro servidor com tabelas `mat_*` (`species`, `plant`, `entry`, `location`, `soil`, `bed`) nunca são reenviados.

### `POST /sync/ack`

Registra o maior `rev` que o dispositivo já puxou do jardim (um cursor por dispositivo e jardim). Só avança, nunca recua. Informativo — alimenta o `/sync/status`.

```json
{ "deviceId": "uuid", "cursor": 57 }
```

### `GET /sync/status`

Retorna o estado de sincronização do dispositivo atual no jardim (eventos pendentes, cursores).

## Fotos

Chave de foto é um nome de arquivo simples (sem `/` nem `..`); cada jardim tem seu próprio diretório no servidor (o do jardim pessoal é o mesmo diretório que a conta usava antes dos jardins). As rotas seguem o header `X-Polypodium-Garden`, como o sync, e respondem `403` a quem não é membro.

- `PUT /photos/<photoKey>` — corpo são os bytes crus da imagem (limite padrão 15 MB). Resposta: `{ "ok": true, "photoKey": "…" }`.
- `GET /photos/<photoKey>` — devolve os bytes com o `Content-Type` inferido da extensão (jpg, png, webp, gif).
- `HEAD /photos/<photoKey>` — `200` se a foto existe, `404` se não, sem corpo. O app usa isso no reenvio acima para não subir de novo os arquivos que já estão no servidor.

## Jardins

Todas exigem autenticação. Cada conta tem um jardim pessoal (id igual ao `userId`, `personal: true`, nome inicialmente vazio) e pode criar outros para compartilhar. Só o **dono** (`owner`) adiciona/remove membros e renomeia; qualquer **membro** lista os membros e pode sair. Um jardim do qual a conta não é membro responde `404`, sem revelar se existe. O jardim pessoal também pode receber membros.

### `GET /gardens`

Jardins de que a conta participa, o pessoal primeiro:

```json
{ "gardens": [
  { "id": "…", "name": "", "personal": true, "role": "owner", "ownerUserId": "…", "ownerEmail": "voce@exemplo.com" },
  { "id": "…", "name": "Horta", "personal": false, "role": "member", "ownerUserId": "…", "ownerEmail": "amiga@exemplo.com" }
] }
```

### `POST /gardens`

Cria um jardim vazio, com a conta como dona. Corpo `{ "name": "Horta" }` (1 a 100 caracteres). Resposta `201`: `{ "id": "…", "name": "Horta", "personal": false, "role": "owner" }`.

### `PATCH /gardens/<id>`

Só o dono. Corpo `{ "name": "…" }`. Resposta `{ "id": "…", "name": "…" }`; `403` para membros.

### `GET /gardens/<id>/members`

Qualquer membro. `{ "members": [ { "userId": "…", "email": "…", "role": "owner", "addedAt": "…" } ] }` — o dono primeiro.

### `POST /gardens/<id>/members`

Só o dono. Corpo `{ "email": "…" }` de uma conta **existente neste servidor** (contas novas continuam sendo criadas pelo admin). `201` com o membro; `404 account not found`; `409 already a member`; `403` para membros.

### `DELETE /gardens/<id>/members/<userId>`

O dono remove um membro; um membro, passando o próprio `userId`, sai do jardim. O dono não pode sair do próprio jardim (`400`); um membro removendo outra conta recebe `403`; `404` se a conta não era membro. Os dados que a conta escreveu permanecem no jardim.

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
| `GET /admin/weather` | Regiões de previsão do tempo (com coordenadas), última busca e último erro |
| `POST /admin/weather/refresh` | Busca a previsão de todas as regiões em uso agora (`409` se desligada) |

`GET /admin/settings` traz `allowMemberExport`, `allowMemberImport`, `weatherEnabled` e `mcpEnabled`; o `PATCH` aceita qualquer subconjunto deles. `GET /admin/me` traz `weatherEnabled` e `mcpEnabled` para qualquer conta.

O app Polypodium expõe tudo isso na tela de administração do servidor.

## Previsão do tempo

Desligada por padrão. Quando um admin liga (`PATCH /admin/settings` com `{"weatherEnabled": true}`), o servidor busca a previsão de todo local (`location`) não excluído que tenha `latitude` e `longitude`, em qualquer jardim, usando o [Open-Meteo](https://open-meteo.com), que é gratuito e não exige chave.

- **Agrupamento:** coordenadas a menos de `WEATHER_CLUSTER_KM` (padrão 5 km) do centro de uma região usam essa região, e cada região gera uma única busca. O centro é a primeira coordenada que criou a região e não muda depois. Só o centro da região é enviado ao provedor.
- **Frequência:** o servidor verifica a cada hora. Uma região nova é buscada na verificação seguinte; uma região já buscada só é atualizada depois de `WEATHER_REFRESH_HOURS` (padrão 24). Se a busca falha, a próxima tentativa ocorre depois de 1 h.
- **Retenção (quanto mais recente, mais detalhe):**
  - **horária:** dos últimos `WEATHER_HOURLY_PAST_DAYS` dias (padrão 2) até o fim da previsão (`WEATHER_FORECAST_DAYS`, padrão 7).
  - **diária:** cerca de `WEATHER_DAILY_RETENTION_DAYS` dias (padrão 365). Os dados são apagados de mês em mês, nunca no meio de um mês.
  - **mensal:** resumo de cada mês completo (médias e extremos de temperatura, chuva total, dias com chuva ≥ 1 mm e ET0 total), mantido enquanto a região existir.
  - Uma região da qual nenhum local se aproxima há `WEATHER_REGION_IDLE_DAYS` dias (padrão 30) é apagada junto com seus dados.
- Cada busca sobrescreve as horas e os dias que já estavam guardados (sempre inclui pelo menos 2 dias passados). Assim, os dias recentes trazem o dado mais próximo do que realmente aconteceu.
- Horas e datas estão no fuso local da região (`timezone`), no mesmo formato em que o provedor as envia.

### `GET /weather/locations/<id>?days=<n>&months=<n>`

Autenticada, com escopo de jardim (`X-Polypodium-Garden`, igual ao sync). Devolve a previsão do local `<id>` do jardim:

```json
{
  "locationId": "…",
  "timezone": "America/Sao_Paulo",
  "elevation": 737.0,
  "fetchedAt": "2026-10-06T12:00:03.000Z",
  "hourly":  [{ "time": "2026-10-06T13:00", "temperature": 23.1, "humidity": 60, "precipitation": 0.0, "precipitationProbability": 10, "weatherCode": 2, "windSpeed": 9.4 }],
  "daily":   [{ "date": "2026-10-06", "weatherCode": 95, "temperatureMax": 23.6, "temperatureMin": 16.2, "precipitationSum": 22.9, "precipitationProbabilityMax": 100, "windSpeedMax": 10.1, "et0": 2.2 }],
  "monthly": [{ "month": "2026-09", "days": 30, "temperatureMaxAvg": 25.1, "temperatureMinAvg": 14.0, "temperatureMax": 31.2, "temperatureMin": 9.8, "precipitationSum": 88.4, "rainyDays": 9, "et0Sum": 96.0 }]
}
```

- `days` (padrão 7): quantos dias passados incluir em `daily`, além de hoje e da previsão.
- `months` (padrão 0): quantos meses completos incluir em `monthly`.
- `weatherCode` segue os códigos WMO; `et0` é a evapotranspiração de referência FAO-56, em mm.
- Como uma região pode ser compartilhada com locais de outras contas, a resposta nunca inclui as coordenadas dela.

Os erros vêm como `404` com um campo `code`: `weather_disabled`, `location_not_found` (inclui local excluído ou de outro jardim), `no_coordinates` ou `weather_pending` (ainda não houve busca para a região; tente depois).

## MCP

O servidor expõe um servidor [MCP](https://modelcontextprotocol.io) (Model Context Protocol) para que assistentes de IA (Claude Code, Claude Desktop, Cursor…) consultem e editem um jardim. **A conexão é por jardim:** cada token MCP pertence a um único jardim e a quem o criou, e o token sozinho define o jardim — não há `X-Polypodium-Garden`.

**Desligado por padrão.** Um admin liga com `PATCH /admin/settings` e `{"mcpEnabled": true}`, ou pela tela de administração do app. Enquanto está desligado:

- `/mcp` responde `404` com `"code": "mcp_disabled"`, mesmo para tokens válidos.
- `POST /gardens/<id>/mcp-tokens` responde `403` com `"code": "mcp_disabled"`.
- Listar e revogar tokens continua funcionando. Os tokens existentes voltam a valer quando o MCP é religado.

### Tokens

Criados pelo próprio membro, com o JWT do app. Valem até serem revogados; deixam de valer na hora se a conta for desativada/removida ou sair do jardim. O servidor só guarda o hash (SHA-256) do segredo.

#### `GET /gardens/<id>/mcp-tokens`

Qualquer membro vê os próprios tokens; o dono vê os de todos. O segredo nunca aparece aqui.

```json
{ "enabled": true, "tokens": [
  { "id": "…", "name": "Claude Desktop", "tokenPrefix": "pmcp_Eggl_L", "canWrite": true,
    "createdAt": "…", "lastUsedAt": "…", "userId": "…", "email": "voce@exemplo.com" }
] }
```

`enabled` diz se o MCP está ligado no servidor. `lastUsedAt` é atualizado no máximo uma vez por minuto.

#### `POST /gardens/<id>/mcp-tokens`

Corpo `{ "name": "Claude Desktop", "canWrite": false }` (`name` com 1 a 100 caracteres; `canWrite` opcional, padrão `false`). Resposta `201` com os mesmos campos da listagem e mais `token` (`pmcp_…`), **mostrado só desta vez**. Limite de 20 tokens por membro por jardim (`409`).

#### `DELETE /gardens/<id>/mcp-tokens/<tokenId>`

Revoga (apaga) o token. O membro revoga os próprios; o dono, qualquer um. `404` para token inexistente ou de outra pessoa (se quem pede não é o dono).

### Endpoint `POST /mcp`

Transporte *Streamable HTTP* do MCP (revisões `2025-06-18` e `2025-03-26`), sem estado: cada mensagem JSON-RPC é um `POST` com `Authorization: Bearer pmcp_…`, e a resposta é JSON puro (sem SSE nem sessão). Notificações recebem `202`. `GET`/`DELETE` respondem `405`. Token ausente, inválido ou revogado: `401` com `WWW-Authenticate: Bearer`.

Exemplo de configuração (Claude Code):

```bash
claude mcp add --transport http polypodium https://seu-servidor/api/v1/mcp \
  --header "Authorization: Bearer pmcp_…"
```

### Ferramentas

| Ferramenta | O que faz |
|---|---|
| `garden_overview` | Contagens, plantas com rega vencida, reaplicação de defensivo vencida, últimos registros |
| `list_plants` | Plantas com espécie, local, vaso e estado da rega; filtros por texto, status, local, vaso, espécie e `needsWater` |
| `get_plant` | Detalhes de uma planta: ficha da espécie, solo, lembretes, registros recentes, número de fotos e a **foto de capa** como imagem (512 px; `includeCoverImage: false` desliga) |
| `list_plant_photos` | Fotos de uma planta, das mais novas para as mais antigas, com o registro de cada uma (data, tipo, nota) e qual é a capa |
| `get_photos` | Até 6 fotos por chamada, como imagens: `small` (512 px), `medium` (1024 px, padrão) ou `large` (1568 px) no lado maior |
| `list_entries` | Registros do diário, mais recentes primeiro; por planta, tipo e intervalo de dias (`hasPhoto` diz se o registro tem foto) |
| `list_species`, `list_locations`, `list_pots`, `list_soils`, `list_defensivos` | Catálogos |
| `get_weather` | Previsão de um local (quando o admin ligou a previsão do tempo) |
| `add_entry` ✎ | Registra rega, adubação, observação etc. em uma ou mais plantas, ou em todas as plantas ativas de um vaso |
| `delete_entry` ✎ | Exclui um registro (e as fotos dele) |
| `create_plant` ✎, `update_plant` ✎ | Cria/edita planta (nome, status, espécie, solo, local, vaso, frequência de rega) |
| `create_species` ✎, `create_location` ✎ | Cria espécie/local |

✎ = só aparece para tokens com `canWrite: true`.

Plantas podem ser indicadas pelo id, pelo código curto de 6 caracteres da etiqueta (`#ABC123`) ou pelo apelido exato. O estado da rega considera a data mais recente entre `lastIrrigatedAt` da planta e o último registro de rega.

**Fotos:** vêm dos arquivos que o sync já guarda (`photoKey` de `entry` e `entry_photo`). Como no app, as fotos extras só contam para um registro que tem foto própria, e a capa é a escolhida na planta (`coverPhotoId`) ou, sem escolha, a foto própria do registro mais recente. O servidor reduz cada foto e a envia em JPEG como conteúdo `image` do MCP, porque os originais podem ter até 15 MB. A redução roda fora do loop de requisições, com no máximo 2 fotos por vez, e as 48 mais recentes ficam em cache na memória.

**Escritas:** o MCP grava pelo mesmo caminho do `POST /sync/receive` (LWW), como mais um dispositivo, com `deviceId` `mcp-<tokenId>`, e no mesmo formato de payload do app. Os aparelhos recebem as mudanças no próximo pull. Referências (espécie, solo, local, vaso, planta) são validadas antes de gravar. Datas só com o dia (`2026-10-12`) viram meio-dia daquele dia, sem fuso, para não mudarem de dia em nenhum fuso horário. Ao excluir um registro de rega ou de defensivo, o servidor também recalcula a última rega/aplicação da planta, porque o app só faz esse recálculo quando recebe um registro novo.

## Saúde

### `GET /health`

Sem autenticação: `{ "status": "ok", "version": "…" }`. Útil para health checks de proxy/monitoramento.
