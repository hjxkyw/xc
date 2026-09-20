use lib 'lib';
use XC::Grammar;

# Diretivas vao inteiras para o pre-processador do TL++. Nada aqui olha
# dentro -- a definicao de um '#command' e uma linguagem propria.
my @casos =
  '#include "totvs.ch"'                              => 'include',
  '#define MAX 100'                                  => 'define',
  "#xtranslate ANOTE <x> => ;\n  conout(<x>)"        => 'xtranslate continuado',
  "#command SOME <a> AND <b> => ;\n  soma(<a>, <b>)" => 'command continuado',
  ;

my $ok = 0;
for @casos -> $c
{
  my $m = XC::Grammar.parse($c.key, rule => 'preproc');
  $ok++ if $m;
  say(($m ?? '  ok    ' !! '  FALHA '), $c.value.fmt('%-24s'),
      $c.key.subst("\n", ' | ', :g));
}
say "\n  $ok de {@casos.elems}";
