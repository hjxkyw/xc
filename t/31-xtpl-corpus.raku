# slow: every file of xtpl's corpus, twice -- a few minutes under rakupp.
# 'rakupp run-tests.raku' leaves it out; 'rakupp run-tests.raku --all' runs it.

use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;
use XC::Check;

# Every source of xtpl's test suite and every example program, in t/xtpl/,
# passes the checks -- with xtpl's own warnings, see below -- and compiles,
# and what comes out is TL++: read back, it parses and compiles to itself.
# The exceptions, each for a stated reason:
#
# - 51_legacy.xtpl exercises xtpl's --legacy mode, for old AdvPL, which xc
#   does not have;
# - a file with 'raw' is not read back: raw text is TL++ only once the
#   preprocessor has applied its #xtranslate and #command rules.
#
# t/xtpl/errors/ holds what xtpl refuses; t/17-xtpl-errors.raku checks it.

my %skip = '51_legacy.xtpl' => 'xtpl --legacy mode';

# The warnings xc shares with xtpl -- never read, returns, areas not opened --
# are xtpl's own, in the .warn next to each test: xc gives the same ones, no
# more and no less (xtpl's other kinds, fusion and the dictionary, are not
# xc's). But for these, where xc warns and xtpl does not: xtpl counts a
# variable's reads by matching its name in text, and sees one in a member of
# the same name ('?.cCity') or in the lines it generated itself (for a
# postfix 'if', a hash read, a fused chain, '?:'). The variables are only
# ever assigned.
my regex shared { 'never read' | 'never used' | 'returns nothing' | 'reach its end' | 'nothing in this function opened' }
my %extra =
  '13_operand_span.xtpl' => ("line 11: 'cCity' is assigned but never read",),
  '15_control.xtpl'      => ("line 6: 'cCity' is assigned but never read", "line 7: 'lDone' is assigned but never read"),
  '27_hash.xtpl'         => ("line 13: 'xValor' is assigned but never read",),
  '31_feed.xtpl'         => ("line 9: 'aCodes' is assigned but never read", "line 10: 'aTop' is assigned but never read"),
  '53_kitchen_sink.xtpl' => ("line 13: 'cName' is assigned but never read", "line 14: 'cPick' is assigned but never read"),
  ;

# The checks, and then the emitter. Not on the output read back: that is
# TL++, not xtpl -- its 'external' lines are gone, for one -- and xtpl's rules
# for names do not apply to it. @expected: the warnings there have to be.
sub compile(Str $src, :@expected, Bool :$checked = True)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  return Nil unless $m;
  if $checked
  {
    my %c = check-all($m.made, lines => $src.lines.elems);
    die "the checks refuse it: line {%c<errors>[0].key}: {%c<errors>[0].value}" if %c<errors>;
    # Of any other kind -- a name nothing declares, say -- there are none.
    my @other = %c<warnings>.grep({ .value !~~ / <shared> / });
    die "a warning: line {@other[0].key}: {@other[0].value}" if @other;
    my @mine = %c<warnings>.map({ "line {.key}: {.value}" }).sort;
    die "the warnings differ from xtpl's:\n          xc:   {@mine.join("\n                ")}\n          want: {@expected.sort.join("\n                ")}"
      unless @mine.join("\n") eq @expected.sort.join("\n");
  }
  emit($m.made, $src)
}

my @files = |dir('t/xtpl/tests').grep(*.extension eq 'xtpl'),
            |dir('t/xtpl/examples').grep(*.d).map({ |dir($_).grep(*.extension eq 'xtpl') });

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
  say("        {$!.message.lines[0]}") if $! && !$v;
}

for @files.sort -> $f
{
  my $name = $f.basename;
  next if %skip{$name}:exists;
  my $label = $f.parent.basename eq 'tests' ?? $name !! "{$f.parent.basename}/$name";

  # As bin/xc reads it: bytes, not 'slurp', so line ends stay as they are.
  my $src = $f.slurp(:bin).decode('utf-8');
  my $warn = $f.subst(/ '.xtpl' $ /, '.warn').IO;
  my @expected = |($warn.e ?? $warn.slurp.lines.grep(/ <shared> /).map({ .subst(/^ 'warning: ' /, '') }) !! ()),
                 |(%extra{$name} // ());
  check "$label compiles, xtpl's warnings with it, and the output compiles to itself", {
    my $once = compile($src, :@expected);
    if $src ~~ m:i/ ^^ \h* 'raw' >> /
    {
      $once.defined                                # raw: not read back
    }
    else
    {
      my $*GENERATED-OK = True;
      $once.defined && compile($once, :!checked) eq $once
    }
  };
}

check "the skipped files are there, so skipping them still means something",
{
  so %skip.keys.all (elem) @files.map(*.basename).Set
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
