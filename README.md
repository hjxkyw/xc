# xc — um compilador de TL++ escrito em Raku

Experimento. Uma gramática Raku para TL++, com o xtpl crescendo dela em vez de
ser aplicado por cima com expressões regulares.

> **Sem qualquer vínculo com a TOTVS.** Projeto pessoal, experimental,
> escrito por uma IA, nunca usado em produção.

## O alvo é TL++, não AdvPL

A diferença importa. TL++ tem `namespace`, tem anotações, e tem tipos
declarados. Uma gramática que tentasse cobrir os dois teria de aceitar tudo
que o AdvPL aceita e mais, e não poderia recusar nada — que é como se chega de
volta à expressão regular.

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
TL++ —, e a gramática mira só TL++. Parte do que não casa não deveria casar.
Um lote de `.tlpp` de verdade daria um número mais honesto, e ainda não há
um.

`exemplos/saldo.tlpp` é o arquivo de referência: pequeno, escrito para
exercitar o que a gramática cobre, e os testes usam ele em vez de depender de
arquivos de fora.

O que já entra:

| | |
|---|---|
| declarações com tipo | `local aLista := {} as Array`, e abreviado (`as A`). O tipo vem **depois** do inicializador: `local nX as Numeric := 1` é recusado |
| literais próprios | `{ : }` para JSON e `{ => }` para hash, que precisam vir antes de `{}` |
| namespaces | `namespace minha.app`, `using namespace tlpp.regex` |
| anotações | `@Get("/saldo/:id")`, com ou sem argumentos |
| expressões | precedência de `.or.` até unário, `&(macro)`, code blocks com atribuição dentro |
| comandos | `if`, `while`, `for`, `do case`, `begin sequence` |

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

Classes (`Class` / `Method` / `EndClass`), `WSRESTFUL`, `@ ... SAY ... GET`,
e o que só aparecer quando esses entrarem.

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
`exit`, `loop`, declaração. Dentro de uma expressão, o que ainda não tem nó
próprio (`o:x(1)[2]`, um code block) fica como texto; nenhum comando fica sem
nó, e um que ficasse faria a ação morrer dizendo qual. `percorre` em
`lib/XC/AST.rakumod` desce em todos os corpos, em ordem de leitura.

A ação precisa do texto, para saber a linha de cada nó:

```raku
my $arvore = XC::Grammar.parse($src, actions => XC::Actions.new(fonte => $src)).made;
```

`t/08-arvore.raku` confere a forma que sai e o que tem de ser recusado.

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

Achados escrevendo isto, com o menor caso de cada. `rakupp_issue.md`, fora do
repositório, é o relato para mandar ao projeto.

**Um defeito, com certeza.** `|` não casa quando uma alternativa tem um
quantificador com `%`, mesmo casando sozinha. Só com `token`, sem espaço
nenhum envolvido:

```raku
token call { 'f(' <e>* % ',' ')' }
token alt  { <call> | <asg> }       # não casa 'f(1,2)'
token alt2 { <call> || <asg> }      # casa
```

Contorno: `||`, que a gramática usa em todo lugar de qualquer jeito.

**Um que talvez seja defeito.** Num `rule`, `<n>+ % <op>` não casa
`1 + 2 - 3` — e casa `1+2-3`. Escrito à mão, `<n> [ <op> <n> ]*`, casa os
dois. Pode ser só o jeito como `%` combina com espaço significativo; sem um
Rakudo aqui para comparar, não dá para dizer. A gramática usa a forma escrita à
mão.

**Uma diferença do Rakudo.** Numa ação, `$/.from` é a posição no texto
inteiro, mas `$/.orig` é só o texto casado — no Rakudo é o alvo inteiro — e
nenhum outro método do casamento devolve o alvo. Por isso `XC::Actions` recebe
o texto de fora. A versão anterior contava as linhas de `.orig` e dava uma
posição relativa; ninguém viu porque todo teste tinha uma linha só.

**E um que não é defeito.** Um `enum` com chaves `Array` ou `Numeric` parecia sair
vazio. Não é defeito do rakupp: o nome continua sendo o tipo do próprio Raku,
e um objeto de tipo dentro de uma string sai vazio. O erro era meu — a árvore
usa strings para os tipos por isso.

Os dois primeiros chegaram a estar descritos aqui de um jeito mais forte do
que a evidência dava: o segundo como "não casa nem captura", que é falso com
`token`, e o terceiro como defeito. Refazendo o menor caso de cada um antes de
escrever o relato é que apareceu.

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
