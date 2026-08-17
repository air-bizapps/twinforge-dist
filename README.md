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

### O que precisa estar instalado

No macOS e no Linux, o `install.sh` exige `curl`, `tar`, `mktemp`, `uname`, `id`, `awk`, um entre
`sha256sum` e `shasum`, e — desde a assinatura do manifest — **`openssl`**. Ele é o verificador da
assinatura, e **não existe caminho que instale sem verificar**: sem `openssl` o script para e diz o
que instalar (`apt-get install openssl`, `dnf install openssl`, `apk add openssl`; o macOS já vem com
ele). Um "pula a verificação se faltar" seria oráculo de downgrade — é exatamente o caminho que quem
controla o manifest quer que exista.

No Windows o `install.ps1` não precisa de nada além do que o sistema já traz: a verificação é .NET
puro (`RSA.ImportParameters` + `VerifyData`), sem binário externo.

O TwinForge instalado **não sobe sem login numa instância da organização**. Instalar é o primeiro
passo; o segundo é o enrollment.

### Variáveis de ambiente

| Variável | Efeito |
|---|---|
| `TWINFORGE_CHANNEL` | canal a instalar (padrão `canary`) |
| `TWINFORGE_HOME` | raiz da instalação (padrão `~/.twinforge`, `%USERPROFILE%\.twinforge` no Windows) |
| `TWINFORGE_DIST_BASE_URL` | base que serve `channels/<canal>.json`. Override de teste local; use para apontar a um manifest servido na sua máquina |
| `TWINFORGE_DIST_PUBKEY_FILE` | (`install.sh`) PEM de chave pública a aceitar **no lugar** das chaves embutidas, sob o id `local-test`. Para testar um manifest assinado localmente |
| `TWINFORGE_DIST_PUBKEY_MODULUS_FILE` | (`install.ps1`) o mesmo, com o módulo em base64 numa linha — o 5.1 não tem parser de PEM, então é outro conteúdo e por isso outro nome |

As duas últimas trocam **qual chave** é confiável, e nada mais. Não existe variável que desligue a
verificação, e isso é decisão, não esquecimento.

`TWINFORGE_DIST_BASE_URL` é a única que muda de onde o instalador busca. Ela é definida por quem
roda o script, não pelo manifest, e por isso aceita `http://` além de `https://` — um servidor
local de teste não tem certificado. Tudo que o **manifest** aponta é obrigatoriamente `https://`.

## O contrato do manifest

Um manifest de canal é um documento JSON com esta forma. Os instaladores **impõem** o que está
abaixo e recusam a instalação quando algo não bate — a mensagem sempre diz qual campo e por quê.

```json
{
  "schemaVersion": 2,
  "channel": "canary",
  "keyId": "2026-08-canary",
  "sequence": 1,
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

Ao lado dele, `channels/<canal>.json.sig`: **uma linha de base64**, ASCII, a assinatura RSA-3072
PKCS#1 v1.5 sobre SHA-256 dos **bytes exatos** do `.json`. Os dois instaladores baixam o `.sig` junto,
verificam, e só então leem qualquer campo. **Manifest sem assinatura ao lado é recusado** — não existe
modo não assinado, e não existe fase de transição.

- **`schemaVersion`** — o **número** `2`, o formato assinado. A string `"2"` não serve. Não há modo
  compatível com o formato antigo, sem assinatura: no instante em que existir um cliente que aceita
  manifest sem assinatura, basta publicar sem assinar para o esquema inteiro não valer nada.
- **`channel`** — precisa ser igual ao canal **pedido**. Sem isso, assinatura válida de `canary` é
  assinatura válida de `stable` para quem consiga servir um arquivo no lugar do outro.
- **`keyId`** — diz **qual** chave assinou. A lista de chaves aceitas é um array desde a primeira
  release (a rotação depende disso e não dá para retroencaixar), e um `keyId` desconhecido é recusa:
  nunca "tenta as outras".
- **`sequence`** — contador monotônico dentro dos bytes assinados. Quem usa é o **updater**, que
  guarda o último visto e recusa bytes antigos ainda que validamente assinados. O instalador **não**
  implementa guarda de replay: instalação nova não tem "último visto" com que comparar. É ausência por
  decisão.
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

### Antes de publicar a primeira release

Os verificadores estão nos dois instaladores e a chave pública `2026-08-canary` já está embutida nos
dois. **Nenhuma release foi publicada ainda** — `channels/` continua vazio até a primeira tag
`tfapp.v*` rodar no repositório de produto, e até lá os instaladores param num 404. Falhar fechado é o
desenho, e uma fase "aceita qualquer coisa enquanto a gente se organiza" é exatamente o buraco que quem
consegue escrever neste repositório usaria.

Quem publica é o pipeline da §3 do desenho
(`docs/superpowers/specs/2026-08-17-assinatura-do-manifest-design.md`, no repositório de produto): três
jobs, sendo o do meio um `sign` num Environment com revisores obrigatórios, restrito a refs de tag, cujo
único segredo é a chave privada e cujo único produto é o `.sig`. Quem tem o token de escrita **neste**
repositório não consegue produzir assinatura, e quem aprova a assinatura não usa o token — é essa
separação que faz os dois conjuntos de pessoas pararem de ser intercambiáveis.

Os dois arquivos de um canal, `canary.json` e `canary.json.sig`, chegam **no mesmo commit** e não podem
ser regerados nem reformatados aqui. A assinatura cobre os bytes exatos: um `jq .` para embelezar, um
editor que acrescente newline no fim, ou um checkout no Windows convertendo LF para CRLF produzem um
manifest que continua *correto* e que todo cliente recusa, com uma mensagem que se lê como sabotagem.

A chave vive em **três lugares**: como PEM no `install.sh`, como módulo em base64 no `install.ps1` (o
PowerShell 5.1 não tem parser de PEM) e como `publicKeyPem` dentro do tarball de release — esta
última é a que o updater usa. `tests/key-parity-test.sh` afirma que as duas cópias visíveis daqui são
a mesma chave, com o mesmo id, expoente 65537 e ao menos 3072 bits; a terceira só é comparável do
repositório de produto, e é `packaging/install-script.test.mjs` lá que afirma que as três batem.
Cópias de uma chave que divergem em silêncio é um modo de falha real: o instalador que continua
funcionando esconde o que parou, até alguém no outro sistema operacional tentar.

## Alterar os instaladores

Abra PR. Não faça push direto na `main` — os dois instaladores foram escritos assim, sem revisão e
sem CI, e a revisão que veio depois encontrou três falhas que só apareceram por serem procuradas.

O CI roda em todo push e PR:

- `shellcheck -s sh -S style` sobre o `install.sh`
- cinco testes de comportamento sob `dash`: parse do manifest (indentado **e** minificado),
  validação de URL, varredura de truncamento, **verificação de assinatura** e **paridade das chaves**
- `PSScriptAnalyzer` e um parse sob **Windows PowerShell 5.1 e PowerShell 7** sobre o `install.ps1`
- a **verificação de assinatura do `install.ps1` rodando de verdade**, sob os dois runtimes, contra
  assinaturas feitas pelo `openssl` no job do Linux e levadas para o Windows como artefato
- ambos os arquivos precisam ser ASCII puro

Nada disso é estilo. O `install.ps1` nunca tinha sido executado por ninguém em máquina nenhuma; a
verificação de assinatura é a **primeira parte dele que alguém de fato roda**, e é a parte em que o
5.1 é diferente do 7 (lá o `RSA.Create()` devolve um `RSACryptoServiceProvider` de CSP legado). As
fixtures vêm do `openssl` e não do próprio .NET de propósito: um teste que assina e verifica com a
mesma biblioteca concorda consigo mesmo faça o que fizer com codificação. E um travessão UTF-8 num
arquivo sem BOM é lido como CP1252 pelo PowerShell 5.1, onde vira aspa — o que já quebrou o arquivo
uma vez, silenciosamente.

## Por que este repositório é separado

O repositório de produto é interno. Este é público para que o download do artefato não exija
credencial — o portão do produto é o login na instância, não o acesso ao arquivo. A separação é de
permissão, não técnica: quem cuida de release trabalha aqui sem precisar de acesso ao código-fonte.

## O que protege quem instala

Este repositório não guarda segredo algum, e isso é de propósito. Mas vale ser explícito sobre o que
isso significa e o que não significa.

O manifest **é a raiz de confiança**. Ele nomeia a URL e o sha256 que todo instalador e todo updater
vão aceitar. Os artefatos são verificados contra o manifest; **o manifest é verificado contra a
assinatura**, e é isso que esta seção passou a poder dizer.

O que a assinatura compra, sendo preciso:

- **Move a fronteira de confiança do repositório público de volta para o privado.** Antes, escrever
  aqui *era* execução de código. Agora produzir assinatura válida custa a chave privada, que vive na
  cerimônia da §3 do desenho e não neste repositório. Cobre token vazado, push direto acidental e PR
  malicioso mergeado aqui.
- **Para o updater, é decisiva.** A chave dele viaja dentro do tarball, para máquinas já instaladas.
  Quem escreve aqui não troca a chave de uma máquina instalada, então o comprometimento deste
  repositório deixa de ser "execução em toda a frota sozinho, em até 6 horas" e vira "execução em quem
  instalar **depois**".
- **Para o primeiro install, ela compra quase nada**, e isso não é conserto de implementação. Quem
  domina este repositório reescreve o `install.sh` e apaga a checagem. Assinatura não resolve
  confiança-no-primeiro-uso, e nenhum esquema que busca o próprio verificador no servidor do atacante
  vai resolver. Quem se importa instala a partir de um commit SHA fixo em vez de `/main`.
- **Não cobre** quem cria uma tag `tf.v*` nem quem edita o workflow de release no repositório de
  produto. O interruptor real contra uma publicação ruim é o `minSupported` e, quando o enrollment
  existir, o handshake da instância — que é um canal autenticado fora do GitHub.

Não há revogação, e fingir que há é o modo de falha: não existe CRL, e um updater não assistido não
consultaria. Uma chave comprometida sai por uma atualização que a remova — assinada por uma chave que
o atacante também tem. Isso é corrida, não controle.
