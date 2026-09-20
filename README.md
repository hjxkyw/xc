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
- **Gerador (`yield`) precisa do mesmo.** Está desenhado no xtpl e não
  construído, e o custo não é o recurso: é o parser.

Então: parse de verdade primeiro.

## Estado

**Uma gramática que parseia, e nada mais.** Não há ações, nem árvore, nem
análise, nem geração de código.

Contra 59 arquivos `.prw`/`.tlpp` de repositórios públicos: **3 casam por
inteiro.** Esse é o número honesto, e é o que torna o exercício útil.

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

### Tipos: parseados, não conferidos

A gramática aceita `local nX := "texto" as Numeric` sem reclamar. Conferir que
o inicializador bate com o tipo declarado é análise, não parse — precisa da
árvore, que ainda não existe.

### E o que ainda não começou

O xtpl. A gramática é de TL++ puro; nada de `|>`, `using alias`, `defer`, `?.`
ou escopo de bloco foi acrescentado. A ideia é que cresçam daqui, mas primeiro
o TL++ tem de entrar inteiro.

## Como rodar

Precisa do [rakupp](https://github.com/ash/rakupp) — uma implementação de
Raku em C++, sem Rakudo e sem zef. Não está no PyPI nem em gerenciador
nenhum; é um anexo de release:

```sh
curl -sfL -O https://github.com/ash/rakupp/releases/download/v4.0.1/rakupp-linux-x86_64.tar.gz
tar xzf rakupp-linux-x86_64.tar.gz
export PATH=$PWD/rakupp/bin:$PATH

rakupp t/01-basico.raku
```

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
