# Os erros do xtpl

Copiados de `errors/` do xtpl (116), que ficou descontinuado e hoje só serve
para o xc nascer. Cada `.xtpl` é um fonte que o xtpl recusa, e o `.err` ao
lado é a mensagem que ele dá.

`t/17-erros-xtpl.raku` os lê e separa em quatro grupos:

- **sintaxe** — a gramática tem de recusar. E cada um tem uma correção, uma
  troca de texto mínima no próprio teste, e o fonte corrigido tem de casar:
  é isso que mostra que a recusa foi pelo erro certo, e não por outra coisa
  do arquivo.
- **análise** — o erro é de nomes, escopo, tipos ou chamadas. A gramática tem
  de aceitar; recusar é trabalho de uma passada de análise que ainda não
  existe.
- **decidido** — o xc aceita de propósito, contra o xtpl.
- **pendente** — usa uma construção que o xc ainda não lê. Aparece na saída,
  mas não conta.

Um arquivo que não esteja em nenhum grupo faz o teste falhar.

As mensagens dos `.err` são as do xtpl, e o xc ainda não dá mensagem
nenhuma: por enquanto elas estão aqui como referência.
