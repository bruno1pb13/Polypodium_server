# Polypodium Server

[![CI](https://github.com/bruno1pb13/Polypodium_server/actions/workflows/ci.yml/badge.svg)](https://github.com/bruno1pb13/Polypodium_server/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/bruno1pb13/Polypodium_server)](https://github.com/bruno1pb13/Polypodium_server/releases/latest)
[![Docker](https://img.shields.io/badge/ghcr.io-polypodium__server-blue?logo=docker)](https://github.com/bruno1pb13/Polypodium_server/pkgs/container/polypodium_server)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Servidor de sincronização self-hosted para o app [Polypodium](https://github.com/bruno1pb13/Polypodium). Sincronize sua coleção de plantas entre aparelhos usando um servidor que é **seu** — sem nuvem de terceiros.

- **Multiusuário** — contas com login (JWT), a primeira conta vira admin e cria as demais.
- **Last-write-wins** — conflitos entre aparelhos são resolvidos de forma determinística, sem intervenção.
- **Tudo incluso** — dados, fotos e painel de administração pelo próprio app.
- **Acesso por IA (MCP)** — opcional e desligado por padrão: assistentes como Claude e Cursor consultam e editam um jardim, inclusive vendo as fotos das plantas.

## Começar rápido

Só precisa de Docker — a imagem pronta está no [ghcr.io](https://github.com/bruno1pb13/Polypodium_server/pkgs/container/polypodium_server). Crie um `docker-compose.yml` e um `.env` conforme o [guia de instalação](docs/deploy.md) e suba:

```bash
docker compose up -d
curl http://localhost:8080/api/v1/health   # → {"status":"ok"}
```

Depois é só apontar o app (Configurações → Servidor) para a URL e criar a primeira conta.

O [guia de instalação](docs/deploy.md) cobre o passo a passo completo: HTTPS com Let's Encrypt, criação do primeiro admin, backups e atualização.

## Acesso por IA (MCP)

O servidor inclui um servidor [MCP](https://modelcontextprotocol.io). Com ele, assistentes de IA leem um jardim (plantas, diário, fotos, catálogos e previsão do tempo) e, se você permitir, registram regas e criam ou editam plantas. As mudanças chegam aos aparelhos no próximo sync, como as de qualquer outro aparelho.

1. **Ligar:** o MCP vem desligado. Um admin liga em *Administração do servidor → Acesso por IA (MCP)*, no app, ou com `PATCH /api/v1/admin/settings` e `{"mcpEnabled": true}`.
2. **Criar um token:** no app, abra o menu do workspace → *Acesso por IA (MCP)* → *Novo token*. Cada token dá acesso a um único jardim, como somente leitura ou com alterações. Ele aparece uma vez só.
3. **Conectar o assistente:** o endpoint é `https://seu-servidor/api/v1/mcp`, com o header `Authorization: Bearer pmcp_…`. No Claude Code:

   ```bash
   claude mcp add --transport http polypodium https://seu-servidor/api/v1/mcp \
     --header "Authorization: Bearer pmcp_…"
   ```

   No Claude Desktop, configure via [`mcp-remote`](https://www.npmjs.com/package/mcp-remote) no `claude_desktop_config.json`. Os conectores do claude.ai exigem OAuth, que o servidor ainda não oferece.

A lista de ferramentas e os detalhes estão em [API → MCP](docs/api.md#mcp).

## Documentação

| Documento | Conteúdo |
|---|---|
| [Instalação e operação](docs/deploy.md) | Docker Compose, HTTPS/proxy reverso, primeiro admin, backups |
| [API](docs/api.md) | Endpoints de autenticação, sincronização, fotos, administração e MCP |
| [Desenvolvimento](docs/desenvolvimento.md) | Rodar localmente, arquitetura, banco de dados, como contribuir |

## Desenvolvimento

```bash
dart pub get
source .env && dart run bin/server.dart
dart test
```

Detalhes de arquitetura e convenções em [docs/desenvolvimento.md](docs/desenvolvimento.md).

## Licença

[MIT](LICENSE)
