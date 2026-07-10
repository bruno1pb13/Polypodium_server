# Polypodium Server

[![CI](https://github.com/bruno1pb13/Polypodium_server/actions/workflows/ci.yml/badge.svg)](https://github.com/bruno1pb13/Polypodium_server/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/bruno1pb13/Polypodium_server)](https://github.com/bruno1pb13/Polypodium_server/releases/latest)
[![Docker](https://img.shields.io/badge/ghcr.io-polypodium__server-blue?logo=docker)](https://github.com/bruno1pb13/Polypodium_server/pkgs/container/polypodium_server)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Servidor de sincronização self-hosted para o app [Polypodium](https://github.com/bruno1pb13/Polypodium). Sincronize sua coleção de plantas entre aparelhos usando um servidor que é **seu** — sem nuvem de terceiros.

- **Multiusuário** — contas com login (JWT), a primeira conta vira admin e cria as demais.
- **Last-write-wins** — conflitos entre aparelhos são resolvidos de forma determinística, sem intervenção.
- **Tudo incluso** — dados, fotos e painel de administração pelo próprio app.

## Começar rápido

Só precisa de Docker — a imagem pronta está no [ghcr.io](https://github.com/bruno1pb13/Polypodium_server/pkgs/container/polypodium_server). Crie um `docker-compose.yml` e um `.env` conforme o [guia de instalação](docs/deploy.md) e suba:

```bash
docker compose up -d
curl http://localhost:8080/api/v1/health   # → {"status":"ok"}
```

Depois é só apontar o app (Configurações → Servidor) para a URL e criar a primeira conta.

O [guia de instalação](docs/deploy.md) cobre o passo a passo completo: HTTPS com Let's Encrypt, criação do primeiro admin, backups e atualização.

## Documentação

| Documento | Conteúdo |
|---|---|
| [Instalação e operação](docs/deploy.md) | Docker Compose, HTTPS/proxy reverso, primeiro admin, backups |
| [API](docs/api.md) | Endpoints de autenticação, sincronização, fotos e administração |
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
