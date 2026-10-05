# Desenvolvimento

## Dependências

| Pacote | Uso |
|---|---|
| Dart ≥ 3.0 | runtime |
| `shelf` + `shelf_router` | servidor HTTP |
| `postgres` ^3.0 | PostgreSQL (driver nativo) |
| `dart_jsonwebtoken` | geração e verificação de JWT |
| `bcrypt` | hash de senhas |
| `uuid` | IDs de dispositivos |

## Rodar localmente

```bash
cp .env.example .env    # e preencha os valores
dart pub get

# Modo desenvolvimento (lê variáveis do .env)
source .env && dart run bin/server.dart

# Compilar para binário nativo
dart compile exe bin/server.dart -o polypodium_server

dart analyze   # lint
dart test      # testes
```

> **Atenção:** os testes usam o banco apontado por `DATABASE_URL` e apagam dados. Nunca rode `dart test` contra um banco com dados reais.

As migrações rodam automaticamente na inicialização (`runMigrations` em `db.dart`), em uma única transação serializada por advisory lock; cada passo é idempotente (`IF NOT EXISTS` ou condicionado ao formato antigo da tabela). Não há ferramenta de migration separada. `test/database/migration_test.dart` cria o esquema anterior em um schema descartável e confere a migração. Os testes rodam um arquivo por vez (`dart_test.yaml`), porque as migrações de um arquivo travariam contra as escritas de outro.

## Estrutura do projeto

```
bin/
└── server.dart               # bootstrap: banco, DI, pipeline, serve

lib/
├── core/
│   ├── config.dart           # variáveis de ambiente
│   ├── http_utils.dart       # leitura de corpo com limite de tamanho
│   └── token_service.dart    # ITokenService + JwtTokenService
├── database/
│   └── db.dart               # initDatabase() → Pool + migrações
├── features/
│   ├── auth/                 # registro bootstrap, login
│   ├── sync/                 # changes/receive/ack/status + LWW
│   ├── gardens/              # jardins e membros
│   ├── photos/               # upload/download por jardim
│   └── admin/                # contas, papéis, configurações
├── middleware/
│   ├── auth_middleware.dart  # valida JWT + reverifica a conta no banco
│   ├── admin_middleware.dart # exige role admin (lê do contexto)
│   ├── cors_middleware.dart
│   ├── error_middleware.dart
│   └── rate_limit_middleware.dart
├── routes/                   # monta os mounts /api/v1/* + /health
└── server/
    └── ssl.dart              # buildSslContext()
```

### Pipeline de requisição

```
errorMiddleware → corsMiddleware → logRequests
  /api/v1/auth/*    → rate limit → AuthHandler        (sem autenticação)
  /api/v1/sync/*    → authMiddleware → gardenMiddleware → SyncHandler
  /api/v1/photos/*  → authMiddleware → gardenMiddleware → PhotoHandler
  /api/v1/gardens/* → authMiddleware → GardenHandler
  /api/v1/admin/*   → authMiddleware → adminOnly → AdminHandler
  GET /api/v1/health
```

`authMiddleware` verifica o Bearer token, **reconsulta a conta no banco a cada requisição** (rejeitando contas removidas ou desativadas) e injeta `userId`, `deviceId` e `role` no `request.context`. Handlers nunca leem identidade do corpo da requisição — o `deviceId` do corpo é apenas validado contra o do token.

`gardenMiddleware` resolve o jardim do header `X-Polypodium-Garden` (ausente → o jardim pessoal, cujo id é o `userId`), confere que a conta é membro (senão `403`) e injeta `gardenId` no contexto. Toda consulta de sync e todo caminho de foto usam esse `gardenId`.

### Injeção de dependência

`bin/server.dart` é o único composition root; a árvore é montada explicitamente, sem framework. Handlers dependem de interfaces (`IAuthRepository`, `ISyncRepository`, `ITokenService`), o que permite substituí-las em testes sem banco.

## Modelo de dados e sincronização

Não há log de eventos — o sync é dirigido por **linhas versionadas**:

Os dados pertencem a **jardins** (`gardens`, com `garden_members` e papéis `owner`/`member`). Toda conta tem um jardim pessoal com `id = user_id` (`personal = TRUE`), criado junto com a conta — e, para contas anteriores, pela migração, que moveu cada linha para o jardim pessoal do dono sem tocar em `rev`. Por isso o diretório de fotos por usuário já é o do jardim pessoal.

As tabelas `mat_*` (`mat_species`, `mat_plants`, `mat_entries`, `mat_entry_photos`, `mat_locations`, `mat_soils`, `mat_beds`, `mat_defensivos`, `mat_reminders`) guardam o estado atual, uma linha por `(garden_id, entity_id)` (PK composta — um UUID gerado no cliente que colida entre dois jardins nunca pode sobrescrever a linha do outro). Cada linha carrega:

- `updated_at` — hora real da edição no aparelho;
- `deleted_at` — tombstone de soft-delete (deletes nunca são físicos);
- `device_id` — último aparelho escritor, e `user_id` — a conta dele (informativo, sem FK: apagar uma conta não apaga o que ela escreveu num jardim compartilhado);
- `rev` — atribuído da sequência compartilhada `mat_rev_seq` a cada escrita, mantendo uma ordenação monotônica única entre todos os tipos de entidade.

**Last-write-wins:** o `INSERT … ON CONFLICT DO UPDATE` só aplica quando `EXCLUDED.updated_at > atual` (desempate por `device_id`). Essa cláusula é a forma SQL do comparador `incomingWins` do pacote compartilhado [`polypodium_core`](https://github.com/bruno1pb13/polypodium_core), que o app usa no pull com a mesma regra (cada linha do app guarda o `deviceId` de quem a escreveu), além do modelo de mudança (`SyncChange`). Um `deviceId` nulo no app equivale à string vazia, que aqui ordena antes de qualquer `device_id`. O `sync_repository_test.dart` executa os vetores de teste do pacote (`lwwVectors`) contra o Postgres, então qualquer divergência entre o SQL e o pacote quebra os testes. Mudar a regra é mudar o pacote, gerar uma nova tag e atualizar o `ref` aqui e no app.

`device_cursors` registra, por `(device_id, garden_id)`, o maior `rev` que cada dispositivo confirmou ter puxado (`POST /sync/ack`) — informativo, alimenta o `/sync/status`; a correção do sync não depende dele.

### Adicionando um novo tipo de entidade

1. Adicione o nome em `_validEntityTypes` e `_matTable` em `sync_repository.dart`.
2. Inclua a tabela na lista do loop de migração em `db.dart`.
3. Handlers e middleware não precisam de mudanças.

## Release

Publicar um release `v*` no GitHub dispara o workflow que builda e envia a imagem para `ghcr.io/bruno1pb13/polypodium_server` (tags `latest` e a versão).
