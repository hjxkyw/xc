# XC::Tipos -- conferir que um inicializador bate com o tipo declarado.
#
# A primeira coisa construida sobre a arvore, e a primeira que uma expressao
# regular nao conseguiria fazer: saber o TIPO de uma expressao exige saber o
# que ela e -- um literal, uma soma, uma chamada -- e nao so como ela se
# parece.
#
#     local nX := "texto" as Numeric      recusado
#     local nX := 1 + 2 as Numeric        aceito: soma de numeros e numero
#     local nX := f() as Numeric          aceito: nao ha como saber
#
# Onde nao ha como saber, nao se reclama. Um verificador que recusa o que nao
# entende e um verificador que ninguem usa.

use XC::AST;

unit module XC::Tipos;

# Os operadores que decidem o tipo sozinhos, seja qual for o operando.
constant @LOGICOS   = ('==', '!=', '<>', '<', '>', '<=', '>=', '$',
                       '.and.', '.or.', '!');
constant @NUMERICOS = ('-', '*', '/', '%', 'neg');

# O tipo de uma expressao, ou '?' se nao da para saber daqui.
sub tipo-de(Expr $e --> Str) is export
{
  return DESCONHECIDO without $e;

  given $e
  {
    when Literal { .tipo }

    when Binaria
    {
      # O no guardado antes: dentro de um 'given' o topico '$_' vira outra
      # coisa, e '.esq' seria chamado numa string.
      my $no = $_;
      my $op = $no.op;

      # Listas, e nao 'when a | b' nem 'when a || b'. A juncao nao vira uma
      # string comum no fim, e 'a || b' vale so 'a' -- com isso '!=' e '<'
      # caiam em "nao sei", e 'local nX := a != b as Numeric' era aceito sem
      # que teste nenhum percebesse.
      return 'Logical' if $op (elem) @LOGICOS;
      return 'Numeric' if $op (elem) @NUMERICOS;

      # '+' soma numeros e concatena strings. So se sabe o resultado se os
      # dois lados dizem a mesma coisa.
      if $op eq '+'
      {
        my $a = tipo-de($no.esq);
        my $b = tipo-de($no.dir);
        return $a if $a eq $b && ($a eq 'Numeric' || $a eq 'Character');
      }

      DESCONHECIDO
    }

    # Uma chamada devolve o que a funcao devolver, e isso nao esta aqui.
    default { DESCONHECIDO }
  }
}

# Os problemas de uma declaracao, um por declarador que nao bate.
sub confere(Declaracao $d --> List) is export
{
  my @problemas;
  for $d.nomes -> $n
  {
    next if $n.declarado eq DESCONHECIDO;       # sem 'as': nada a conferir
    next without $n.inicial;                    # sem inicializador
    my $achado = tipo-de($n.inicial);
    next if $achado eq DESCONHECIDO;            # nao da para saber
    next if $n.declarado eq 'Variant';          # aceita qualquer coisa

    # Nil cabe em qualquer tipo: e como TL++ escreve "ainda nao".
    next if $n.inicial ~~ Literal && $n.inicial.texto.lc eq 'nil';

    if $achado ne $n.declarado
    {
      @problemas.push:
        "linha {$n.linha}: '{$n.nome}' e declarado as {$n.declarado}, "
        ~ "mas o valor inicial e {$achado}";
    }
  }
  @problemas.List
}
