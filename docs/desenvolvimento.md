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

As migrações DDL rodam automaticamente na inicialização (`CREATE TABLE IF NOT EXISTS`). Não há ferramenta de migration separada.

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
│   ├── photos/               # upload/download por usuário
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
  /api/v1/sync/*    → authMiddleware → SyncHandler
  /api/v1/photos/*  → authMiddleware → PhotoHandler
  /api/v1/admin/*   → authMiddleware → adminOnly → AdminHandler
  GET /api/v1/health
```

`authMiddleware` verifica o Bearer token, **reconsulta a conta no banco a cada requisição** (rejeitando contas removidas ou desativadas) e injeta `userId`, `deviceId` e `role` no `request.context`. Handlers nunca leem identidade do corpo da requisição — o `deviceId` do corpo é apenas validado contra o do token.

### Injeção de dependência

`bin/server.dart` é o único composition root; a árvore é montada explicitamente, sem framework. Handlers dependem de interfaces (`IAuthRepository`, `ISyncRepository`, `ITokenService`), o que permite substituí-las em testes sem banco.

## Modelo de dados e sincronização

Não há log de eventos — o sync é dirigido por **linhas versionadas**:

As tabelas `mat_*` (`mat_species`, `mat_plants`, `mat_entries`, `mat_locations`, `mat_soils`, `mat_beds`, `mat_defensivos`, `mat_reminders`) guardam o estado atual, uma linha por `(user_id, entity_id)` (PK composta — um UUID gerado no cliente que colida entre dois usuários nunca pode sobrescrever a linha do outro). Cada linha carrega:

- `updated_at` — hora real da edição no aparelho;
- `deleted_at` — tombstone de soft-delete (deletes nunca são físicos);
- `device_id` — último escritor;
- `rev` — atribuído da sequência compartilhada `mat_rev_seq` a cada escrita, mantendo uma ordenação monotônica única entre todos os tipos de entidade.

**Last-write-wins:** o `INSERT … ON CONFLICT DO UPDATE` só aplica quando `EXCLUDED.updated_at > atual` (desempate por `device_id`). Essa cláusula é a forma SQL do comparador `incomingWins` do pacote compartilhado [`polypodium_core`](https://github.com/bruno1pb13/polypodium_core), que o app usa no pull com a mesma regra (cada linha do app guarda o `deviceId` de quem a escreveu), além do modelo de mudança (`SyncChange`). Um `deviceId` nulo no app equivale à string vazia, que aqui ordena antes de qualquer `device_id`. O `sync_repository_test.dart` executa os vetores de teste do pacote (`lwwVectors`) contra o Postgres, então qualquer divergência entre o SQL e o pacote quebra os testes. Mudar a regra é mudar o pacote, gerar uma nova tag e atualizar o `ref` aqui e no app.

`device_cursors` registra o maior `rev` que cada dispositivo confirmou ter puxado (`POST /sync/ack`) — informativo, alimenta o `/sync/status`; a correção do sync não depende dele.

### Adicionando um novo tipo de entidade

1. Adicione o nome em `_validEntityTypes` e `_matTable` em `sync_repository.dart`.
2. Inclua a tabela na lista do loop de migração em `db.dart`.
3. Handlers e middleware não precisam de mudanças.

## Release

Publicar um release `v*` no GitHub dispara o workflow que builda e envia a imagem para `ghcr.io/bruno1pb13/polypodium_server` (tags `latest` e a versão).
