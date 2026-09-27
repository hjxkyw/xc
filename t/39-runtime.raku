# The runtime, runtime/xtpl_runtime.tlpp, is TL++: it runs in Protheus, not
# here -- t/protheus/xc_selftest.xtpl checks what it answers, through
# run-protheus.raku. What can be checked here is its shape: that the four
# functions that were quadratic, or could be, stay linear (join: log-linear).

my $rt = slurp('runtime/xtpl_runtime.tlpp');

# One function's text, from its header to its Return.
sub function(Str $name --> Str)
{
  ~($rt ~~ / [ 'User' | 'Static' ] ' Function ' $name '(' .*? \n 'Return' \N* /) // ''
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

check "distinct: one pass -- the values seen are filed in a hash, not scanned",
{
  my $f = function('xtpl_distinct');
  $f.contains('THashMap():New()') && $f.contains('xtpl_seen(oSeen, aData[nX])') && !$f.contains('For nY')
};
check "distinct: filed by type and text, and compared with == as before",
{
  my $f = function('xtpl_seen');
  $f.contains('ValType(xValue)') && $f.contains('cValToChar(xValue)') && $f.contains('aSame[nX] == xValue')
};
check "split: the search goes on from where it stopped, and the rest of the text is never cut off",
{
  my $f = function('xtpl_split');
  $f.contains('At(cSep, cText, nFrom)') && !$f.contains('cText := SubStr(cText')
};
check "split: a space is a separator -- Empty() is not the test for none",
{
  my $f = function('xtpl_split');
  !$f.contains('Empty(cSep)') && $f.contains('Len(cSep) == 0')
};
check "sortBy: each key evaluated once, before the sort; the comparisons read the keys",
{
  my $f = function('xtpl_sortby');
  $f.contains('aPairs[nX] := {Eval(bKey, aRes[nX]), aRes[nX]}')
    && $f.lines.grep(*.contains('aSort(')).grep(*.contains('Eval(')).elems == 0
};
check "join: nothing appended to a growing text in a loop -- the pieces joined pairwise",
{
  my $f = function('xtpl_join');
  my $c = function('xtpl_concat');
  !$f.contains('+=') && $f.contains('Return xtpl_concat(aPieces)')
    && $c.contains('aLevel[2 * nX - 1] + aLevel[2 * nX]') && $c.contains('aLevel := aNext')
};
check "nowhere in the runtime is a string cut and assigned back to itself in a loop",
{
  # 'cX := SubStr(cX, ...)' inside a For or a While: a copy of the rest each round.
  my $depth = 0;
  my $bad = False;
  for $rt.lines -> $l
  {
    my $t = $l.trim;
    $depth++ if $t ~~ m:i/ ^ [ 'For ' | 'While ' ] /;
    $depth-- if $t ~~ m:i/ ^ [ 'Next' | 'EndDo' ] >> /;
    $bad = True if $depth > 0 && $t ~~ / ^ (c \w+) \h* ':=' \h* 'SubStr(' \h* $0 \W /;
  }
  !$bad
};
check "the runtime is still plain ASCII",
{
  so 'runtime/xtpl_runtime.tlpp'.IO.slurp(:bin).list.all < 128
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
