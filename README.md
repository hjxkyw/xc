# xc — o compilador do xtpl, escrito em Raku

Experimento. Uma gramática Raku para o xtpl — o TL++ com extensões —, para o
xtpl crescer dela em vez de ser aplicado por cima com expressões regulares.

> **Sem qualquer vínculo com a TOTVS.** Projeto pessoal, experimental,
> escrito por uma IA, nunca usado em produção.

## xtpl entra, TL++ sai

Como TypeScript e JavaScript. A gramática é a do TL++ aumentada com as
extensões do xtpl, e o compilador baixa um fonte xtpl para TL++ puro: o que já
é TL++ passa como está, e só as extensões são reescritas.

Duas consequências:

- **Todo TL++ válido é xtpl válido.** Um `.tlpp` que não casa é defeito da
  gramática.
- **A régua para recusar é a do xtpl**, não a do TL++. O tipo antes do
  inicializador — `local nX as Numeric := 1` — o TL++ recusa e o xtpl aceita;
  aqui entra, e baixar é trocar as duas partes de lugar.

AdvPL não é alvo. TL++ tem `namespace`, anotações e tipos declarados; uma
gramática que cobrisse os dois teria de aceitar tudo que o AdvPL aceita e mais,
e não poderia recusar nada — que é como se chega de volta à expressão regular.

## Por que

[xtpl](https://github.com/hjxkyw/xtpl) funciona — compila, roda, e passa por
121 arquivos reais. Mas lê o programa linha a linha com expressões regulares,
e isso tem um teto:

- **Não há estrutura.** Cada limpeza da saída virou um *peephole* sobre texto
  gerado, procurando linhas que *se parecem com* `X->(DbGoto(frc_1_0))`. Mude
  o que se emite e o padrão para de casar, calado.
- **Eliminar código morto precisa de caminhos.** "Nada lê este nome mais
  abaixo" não é "nada lê depois": dentro de um laço, a leitura pode estar
  acima da escrita. Isso precisa das arestas — um grafo de fluxo —, e um grafo
  precisa da estrutura que as linhas não têm.

Então: parse de verdade primeiro.

## Estado

**Uma gramática e a árvore que ela produz.** Da análise, só a conferência de
tipos das declarações; não há geração de código.

Contra 59 arquivos de repositórios públicos: **4 casam por inteiro.** Medido
antes de a quebra de linha passar a terminar o comando (abaixo), e não
medido de novo desde então.

Esse número mede menos do que parece. Quase todos são `.prw` — AdvPL, não
TL++ —, e parte do que não casa não deveria casar. Um lote de `.tlpp` de
verdade daria um número mais honesto: ali, tudo tem de casar.

`exemplos/saldo.xtpl` é o fonte de referência: pequeno, escrito para
exercitar o que a gramática cobre, e os testes usam ele em vez de depender de
arquivos de fora. É xtpl, não TL++ puro — o `{ => }` do hash é do xtpl.

Das extensões do xtpl, a gramática conhece o hash `{ => }`, o tipo antes do
inicializador, e as declarações de bloco no cabeçalho: `for local i := …`,
`if local x := …, cond`, `while local x := …, cond`, e `do case with [local]
x := …`. Uma declaração no corpo de um bloco já era um comando como outro
qualquer. E os modificadores posfixados: `x := 1 if c`, `return n if c`,
`f() while c`, `exec f() if c`. E o lambda `[o] o:nValor`, de um a seis
nomes, e as cadeias `|>`. E os operadores: `h{"k"}` e `has`, `in`,
`lo..hi`, `%%`, `?:`, `?.`, `?=`, e as marcas `<const>`/`<contained>`. E
`defer` e `fallback`. O resto está por fazer — `for x in`, `for n times`,
`with object`, `using alias`, `external`, interpolação, `raw`, `queue` (ver
`docs/language.md` do xtpl).

O que já entra:

| | |
|---|---|
| declarações com tipo | `local aLista := {} as Array`, e abreviado (`as A`). O tipo antes do inicializador — `local nX as Numeric := 1` — é do xtpl; o tipo duas vezes é recusado |
| cabeçalhos | `user`, `static` e `main function`, e o `function` solto, que o TL++ aceita quando o nome começa com `u_` (o xtpl, hoje, ainda o recusa) |
| literais próprios | `{ : }` para JSON, e `{ => }` para hash (do xtpl), que precisam vir antes de `{}` |
| namespaces | `namespace minha.app`, `using namespace tlpp.regex` |
| anotações | `@Get("/saldo/:id")`, com ou sem argumentos |
| expressões | precedência de `.or.` até unário, `&(macro)`, code blocks com atribuição dentro, e chamadas qualificadas (`totvs.tools.X():New()`) |
| comandos | `if`, `while`, `for`, `do case`, `begin sequence` |
| lambdas | `[o] o:nValor`, `[acc, x] acc + x` — de um a seis nomes, um corpo (expressão ou atribuição) que para na vírgula de quem o contém |
| cadeias | `aP \|> filter([o] …) \|> map([o] …)`: o valor da esquerda vira o primeiro argumento da etapa; o `\|>` é o nível mais frouxo; como comando, como argumento, com modificador. Não dentro de um lambda ou code block |
| operadores | hash `h{"k"}` (o `{` colado no nome) e `has`; `in`, com `lo..hi` à direita; `%%`; `?:`, pela direita, entre `.or.` e `\|>`; `?.` em membro; `?=` só como comando; `lo..hi` também como fonte de cadeia |
| `defer` | `defer <comando>`: atribuição, cadeia ou chamada, em qualquer bloco, sem modificador |
| `fallback` | `expr fallback alt`, só no valor de uma atribuição, declaração ou `return`, ou entre parênteses; protege a cadeia inteira; não dentro de um lambda |
| marcas | `local x <const, contained> := …` — `<const>` exige valor |
| modificadores | `if` e `while` no fim de um comando simples (`return`, `exit`, `loop`, atribuição, chamada, `exec`) — não de um bloco nem de uma declaração |
| classes | `Class … EndClass` (`From`, `Data`, assinaturas `Method` com `Constructor` e tipo de retorno), e as implementações `Method … Class Nome`; `::x` no corpo |
| locais de bloco | no cabeçalho: `for local i`, `if local x := …, cond`, `while local …, cond`, `do case with [local] …` |

O primeiro arquivo real levou umas quinze correções para passar — cada uma
achada porque a gramática **recusou uma linha e disse qual**:

| o que faltava | o que era |
|---|---|
| `MSDialog():New(...)` | método chamado no resultado de uma chamada |
| `oDlg:Activate( ,,,.T.)` | argumentos vazios, que querem dizer "pula estes" |
| `{ \| u \| If(c, a, cA := u) }` | atribuição como expressão dentro de um bloco |
| `&(alltrim(cX))` | o operador macro |
| `oDlg:End()` | um método que se chama como uma palavra reservada |
| `If(c, a, b)` | o ternário, cujo nome é `if` |
| `return (.t.)` | que casava como chamada a uma função chamada `return` |

As três últimas são a mesma tensão vista de três lados: **onde vale a lista de
palavras reservadas.** Aplicada a todo identificador, recusa `If()` e
`oDlg:End()`. Removida, `return (.t.)` vira uma chamada e o corpo engole o
return. A resposta é que ela vale onde um *comando* começa — e em nenhum outro
lugar.

Uma expressão regular não faz nenhuma dessas perguntas. Aceita tudo e erra
depois.

### O que falta

`WSRESTFUL`, `@ ... SAY ... GET`, e o que só aparecer quando esses entrarem.
Classes (`Class` / `Method` / `EndClass`) já entram — nativas do TL++, como os
caminhos pontuados.

Diretivas de pré-processador — `#include`, `#define`, `#command`,
`#xtranslate` — vão inteiras para o pré-processador do TL++, inclusive quando
continuam em várias linhas com `;`. Nada aqui olha o que há dentro: a
definição de um `#command` é uma linguagem própria, e não é a nossa.

### Um comando por linha

Em AdvPL a quebra de linha termina o comando, a não ser que a linha acabe em
`;`. A gramática tratava a quebra como um espaço qualquer, e um comando podia
continuar na linha de baixo:

```
return          o valor do return virava 'endif',
endif           e o arquivo inteiro deixava de casar

return          o valor virava 'user', e a função seguinte passava
                a ser um 'function g()' sem 'user' -- esta, calada
user function g()
```

Agora `<.ws>` não atravessa linha, e cada lugar onde uma pode acabar diz isso
com `<.nl>`. Linhas em branco e só de comentário ficam dentro do `<.nl>`.

### A árvore, e a primeira coisa construída sobre ela

`lib/XC/Actions.rakumod` transforma o casamento em árvore: o arquivo, as
funções com parâmetros e anotações, e todos os comandos — `if`/`elseif`/`else`,
`do case`, `while`, `for`, `begin sequence`, atribuição, chamada, `return`,
`exit`, `loop`, declaração — e as expressões inteiras: índice, membro,
método, campo de área (`SA1->A1_NOME`, `(cAlias)->A1_NOME`), macro, passagem
por referência, argumento omitido, code block, e os literais com as suas
partes. Nada fica como texto: um nome lido dentro de `aTitulos[nX]:nSaldo` é
um nó. Uma forma sem nó faz a ação morrer dizendo qual, em vez de sumir.

`percorre` desce nos corpos dos comandos e `percorre-expr` nas expressões,
os dois em ordem de leitura; `exprs-de` dá as expressões de um comando.

A estrutura mostrou um defeito que o texto escondia: `{ "a": nX }` casava
como um **array**, cujo item era o membro `nX` da string `"a"` — o `:` do par
virava o de um membro. Com `{ "a": 1 }` não acontecia, porque um número não é
nome de membro. Agora um literal não leva trailer.

A ação precisa do texto, para saber a linha de cada nó:

```raku
my $arvore = XC::Grammar.parse($src, actions => XC::Actions.new(fonte => $src)).made;
```

`t/08-arvore.raku` e `t/09-expressoes.raku` conferem a forma que sai e o que
tem de ser recusado.

`lib/XC/Tipos.rakumod` confere que o inicializador bate com o tipo declarado:

```
local nX := "texto" as Numeric     recusado: o valor inicial é Character
local lB := 1 + 1 as Logical       recusado: o valor inicial é Numeric
local nX := a != b as Numeric      recusado: o valor inicial é Logical
local nX := f() as Numeric         aceito: não há como saber daqui
```

É a primeira coisa que uma expressão regular não conseguiria fazer: saber o
tipo de `1 + 1` exige saber que é uma soma de dois números, e não só como a
linha se parece.

**Onde não há como saber, não se reclama.** Uma chamada devolve o que a função
devolver, e isso não está na linha. Um verificador que recusa o que não
entende é um verificador que ninguém usa.

`t/07-conferencia.raku` testa as duas direções — o que passa e o que é
recusado. Um verificador testado só pelo que recusa pode estar recusando tudo;
testado só pelo que aceita, pode estar aceitando tudo. O segundo aconteceu:
por um tempo `!=`, `<` e `>=` caíam em "não sei", e nada percebeu até entrar
um caso de cada.

## O que o rakupp 4.0.1 faz diferente

Achados escrevendo isto, e conferidos contra o Rakudo 2026.08. Mais de um que
estava aqui como defeito do rakupp era o próprio Raku — o Rakudo faz igual.

**Dois defeitos, relatados ao projeto.**

Numa alternância `||`, uma captura quantificada (`<x>?`, `<x>*`) feita numa
alternativa que depois **falha** não é descartada: ela se junta à da
alternativa que casou. Com `<marcas>?` nas quatro alternativas do declarador,
`local x <contained>` voltava com a marca quatro vezes. Uma captura sem
quantificador não vaza, e `|` também não. O remédio é capturar o que é comum
uma vez, antes das alternativas.

Num submatch — sub-regra, captura nomeada, ou captura posicional numa
gramática —, `.orig` e `.target` devolvem só o texto casado, e não o alvo
inteiro; `.prematch` e `.postmatch` saem errados junto. `.from` e `.to` estão
certos. Por isso `XC::Actions` recebe o texto de fora. A versão anterior
contava as linhas de `.orig` e dava uma posição relativa; ninguém viu porque
todo teste tinha uma linha só.

**Uma diferença ainda não reduzida.** Com `<expr>* % ","` dentro de uma das
alternativas de um `|`, num `rule`, o Rakudo casa e o rakupp não:

```raku
rule alt  { <call> | <asg> }
rule call { <name> "(" <expr>* % "," ")" }
rule asg  { <name> ":=" \d+ }
# 'f("a")': o Rakudo casa, o rakupp não. Sem o '% ","', os dois casam.
```

Com `token` em vez de `rule`, os **dois** recusam — então o caso com `token`
que estava aqui como "menor caso" não reproduzia defeito nenhum. A gramática
usa `||` de qualquer jeito, pela razão de projeto que está no cabeçalho dela.

**E os que são o Raku, não o rakupp.** O Rakudo 2026.08 faz igual:

- Num `rule`, `<n>+ % <op>` não casa `1 + 2 - 3` e casa `1+2-3`. A gramática
  escreve cada nível como `<n> [ <op> <n> ]*`.
- Uma captura com apelido, `<ate=addexpr>`, também entra no nome original:
  dois `<addexpr>` no mesmo nível viram uma lista em `$<addexpr>`. Por isso as
  partes levam nome próprio.
- `$<kw>=[ 'if' || 'while' ]` dentro de um `rule` captura o espaço que vem
  depois da palavra.
- Um `enum` com chaves `Array` ou `Numeric` parecia sair vazio: o nome continua
  sendo o tipo do próprio Raku, e um objeto de tipo dentro de uma string sai
  vazio. A árvore usa strings para os tipos por isso.

## Como rodar

Precisa do [rakupp](https://github.com/ash/rakupp) — uma implementação de
Raku em C++, sem Rakudo e sem zef. Não está no PyPI nem em gerenciador
nenhum; é um anexo de release:

```sh
curl -sfL -O https://github.com/ash/rakupp/releases/download/v4.0.1/rakupp-linux-x86_64.tar.gz
tar xzf rakupp-linux-x86_64.tar.gz
export PATH=$PWD/rakupp/bin:$PATH

rakupp testes.raku
```

Roda tudo em `t/`, soma os placares `N de M` e sai com 1 se algum teste
falhar, morrer no meio ou não imprimir placar. Um teste avulso ainda roda
sozinho: `rakupp t/04-tipos.raku`.

## Alternância ordenada em todo lugar

A gramática usa `||` e nunca `|`. Duas razões:

**De projeto:** numa gramática de linguagem a ordem das alternativas *é* a
especificação. `declaracao || atribuicao` diz que uma linha que poderia ser as
duas é uma declaração. O `|` do Raku escolhe a mais longa, que é uma regra
sobre o texto e não sobre a linguagem.

**E um defeito do rakupp 4.0.1:** uma alternativa que contém uma sub-regra
quantificada com separador falha dentro de uma alternância, e casa sozinha:

```raku
rule  call { <name> '(' <expr>* % ',' ')' }
rule  asg  { <name> ':=' \d+ }
rule  alt  { <call> | <asg> }       # não casa 'f("a")'
rule  alt2 { <call> || <asg> }      # casa
```

Como `||` é o que se quer de qualquer jeito, isto não é uma concessão.

## Licença

MIT.
