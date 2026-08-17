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

### Variáveis de ambiente

| Variável | Efeito |
|---|---|
| `TWINFORGE_CHANNEL` | canal a instalar (padrão `canary`) |
| `TWINFORGE_HOME` | raiz da instalação (padrão `~/.twinforge`, `%USERPROFILE%\.twinforge` no Windows) |
| `TWINFORGE_DIST_BASE_URL` | base que serve `channels/<canal>.json`. Override de teste local; use para apontar a um manifest servido na sua máquina |

`TWINFORGE_DIST_BASE_URL` é a única que muda de onde o instalador busca. Ela é definida por quem
roda o script, não pelo manifest, e por isso aceita `http://` além de `https://` — um servidor
local de teste não tem certificado. Tudo que o **manifest** aponta é obrigatoriamente `https://`.

## O contrato do manifest

Um manifest de canal é um documento JSON com esta forma. Os instaladores **impõem** o que está
abaixo e recusam a instalação quando algo não bate — a mensagem sempre diz qual campo e por quê.

```json
{
  "version": "2026.816.0",
  "artifacts": {
    "darwin-arm64": {
      "url": "https://.../twinforge-2026.816.0-darwin-arm64.tar.gz",
      "sha256": "2222222222222222222222222222222222222222222222222222222222222222"
    },
    "linux-x64":  { "url": "https://...", "sha256": "..." },
    "win-x64":    { "url": "https://...", "sha256": "..." }
  }
}
```

- **`version`** — usado como **nome de diretório** em `versions/<version>/`. Só letras, dígitos,
  ponto, sublinhado e hífen; `.` e `..` são recusados por nome, e qualquer nome que normalize para
  outra coisa também. Não é entrada livre: é um componente de caminho.
- **`artifacts.<plataforma>.url`** — precisa ser `https://`. Sem exceção, e sem redirecionamento
  para fora de https. Um manifest não escolhe o esquema pelo qual o instalador fala.
- **`artifacts.<plataforma>.sha256`** — 64 caracteres hexadecimais. A comparação é case-insensitive
  dos dois lados, porque `sha256sum` devolve minúsculo e o `Get-FileHash` do PowerShell devolve
  maiúsculo. Verificado **antes** de qualquer extração.
- Uma plataforma ausente de `artifacts` é recusada nomeando quais existem.

**A formatação não importa.** O parser lê JSON com consciência de profundidade, então minificado
(`jq -c`) e indentado dão o mesmo resultado. Isso é imposto por teste: `tests/manifest-parse-test.sh`
roda as duas formas. Antes disso, um manifest minificado instalava o artefato da **plataforma
errada** — e como url e sha256 vinham do mesmo bloco errado, o checksum conferia e a instalação
declarava sucesso.

## Canais

- `channels/canary.json` — versões de validação interna; **o único canal aberto hoje**, e o padrão
  dos dois instaladores
- `channels/stable.json` — liberado apenas quando o enrollment existir

Nenhum dos dois existe ainda: eles nascem quando o pipeline do repositório de produto publica a
primeira release. Até lá os instaladores buscam o manifest e param num 404.

## Alterar os instaladores

Abra PR. Não faça push direto na `main` — os dois instaladores foram escritos assim, sem revisão e
sem CI, e a revisão que veio depois encontrou três falhas que só apareceram por serem procuradas.

O CI roda em todo push e PR:

- `shellcheck -s sh -S style` sobre o `install.sh`
- três testes de comportamento sob `dash`: parse do manifest (indentado **e** minificado),
  validação de URL, e a varredura de truncamento
- `PSScriptAnalyzer` e um parse sob **Windows PowerShell 5.1 e PowerShell 7** sobre o `install.ps1`
- ambos os arquivos precisam ser ASCII puro

As duas últimas regras não são estilo. O `install.ps1` nunca foi executado por ninguém em máquina
nenhuma, então o parse é a única coisa que o verifica. E um travessão UTF-8 num arquivo sem BOM é
lido como CP1252 pelo PowerShell 5.1, onde vira aspa — o que já quebrou o arquivo uma vez, silenciosamente.

## Por que este repositório é separado

O repositório de produto é interno. Este é público para que o download do artefato não exija
credencial — o portão do produto é o login na instância, não o acesso ao arquivo. A separação é de
permissão, não técnica: quem cuida de release trabalha aqui sem precisar de acesso ao código-fonte.

## O que protege quem instala

Este repositório não guarda segredo algum, e isso é de propósito. Mas vale ser explícito sobre o que
isso significa e o que não significa.

O manifest **é a raiz de confiança**. Ele nomeia a URL e o sha256 que todo instalador e todo updater
vão aceitar. Quem consegue escrever em `channels/canary.json` consegue executar código em toda
máquina que instalar ou atualizar a partir daqui.

Hoje o que protege isso é a permissão de escrita do repositório, e mais nada — **não há assinatura**.
Os artefatos são verificados contra o manifest; o manifest não é verificado contra nada. Antes de
divulgar a URL de instalação para além de quem já tem acesso de escrita aqui, isso merece uma
decisão explícita.
