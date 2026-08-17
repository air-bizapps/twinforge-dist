# twinforge-dist

Canal de distribuição do TwinForge instalável.

Este repositório contém **apenas** o instalador, os manifests de canal e os artefatos de release.
Não contém código de aplicação: os tarballs são montados pelo pipeline do repositório de produto e
publicados aqui.

## Instalação

```sh
curl -fsSL https://raw.githubusercontent.com/air-bizapps/twinforge-dist/main/install.sh | sh
```

```powershell
irm https://raw.githubusercontent.com/air-bizapps/twinforge-dist/main/install.ps1 | iex
```

Ambos instalam do canal `canary`, que é o único canal aberto por ora — `stable` só abre quando o
enrollment existir. Para instalar de outro canal: `TWINFORGE_CHANNEL=<canal>`.

O TwinForge instalado **não sobe sem login numa instância da organização**. Instalar é o primeiro
passo; o segundo é o enrollment.

## Canais

- `channels/canary.json` — versões de validação interna; **o único canal aberto hoje**, e o padrão
  dos dois instaladores
- `channels/stable.json` — liberado apenas quando o enrollment existir

## Plataformas

`darwin-arm64`, `linux-x64` e `win-x64` na primeira versão. O payload é específico de plataforma:
cada uma é construída inteira, porque as dependências nativas entram já resolvidas para o alvo.

## Por que este repositório é separado

O repositório de produto é interno. Este é público para que o download do artefato não exija
credencial — o portão do produto é o login na instância, não o acesso ao arquivo. A separação é de
permissão, não técnica: quem cuida de release trabalha aqui sem precisar de acesso ao código-fonte.

Este repositório não guarda segredo algum. Quem publica é o pipeline do repositório de produto,
usando um token de escrita que vive lá.
# teste de protecao
