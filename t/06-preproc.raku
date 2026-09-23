use lib 'lib';
use XC::Grammar;

# Directives go whole to the TL++ preprocessor. Nothing here looks inside --
# the body of a '#command' is a language of its own.
my @cases =
  '#include "totvs.ch"'                              => 'include',
  '#define MAX 100'                                  => 'define',
  "#xtranslate ANOTE <x> => ;\n  conout(<x>)"        => 'continued xtranslate',
  "#command SOME <a> AND <b> => ;\n  soma(<a>, <b>)" => 'continued command',
  ;

my $ok = 0;
for @cases -> $c
{
  my $m = XC::Grammar.parse($c.key, rule => 'preproc');
  $ok++ if $m;
  say(($m ?? '  ok    ' !! '  FAIL  '), $c.value.fmt('%-24s'),
      $c.key.subst("\n", ' | ', :g));
}
say "\n  $ok of {@cases.elems}";
exit($ok == @cases.elems ?? 0 !! 1);
