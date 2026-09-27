use lib 'lib';
use XC::Grammar;
use XC::Source;

# What made xc eight times faster, kept from coming back. Nothing here times
# anything -- times vary; counts do not.

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# rakupp 4.0.1 runs the actions of an alias -- '<cond=expr>' -- twice, and
# those of the whole tree under it (Rakudo: once), so aliases on the way down
# multiplied each other. The grammar names those parts with tokens of their
# own. These few are left: 'for' and 'with' parts, short and rare -- and
# 'from' and 'to' could not be tokens, they are Match methods.
check 'no alias onto an expression or a body, but the few known',
{
  my @found = 'lib/XC/Grammar.rakumod'.IO.lines.grep({ !/^ \s* '#' / })
    .map({ |.comb(/ '<' (<[a..z]> <[a..z0..9-]>*) '=' [ 'expr' | 'guardexpr' | 'addexpr' | 'blockexpr' | 'body'
                     | 'closedbody' | 'funcbody' | 'withbody' | 'forrange' | 'rangeexpr' | 'inrhs' ] '>' /) })
    .map({ .subst(/ '=' .* /, '').substr(1) }).unique.sort;
  @found.join(' ') eq 'count from order srange step subject to'
};
check 'the actions run once a node: an assignment in a while in an if in a function',
{
  my $calls = 0;
  my class Counting { method postfix($/) { $calls++ } }
  my $src = "user function f(a, b, c)\n  if a > 0\n    while b\n      a := b + c * 2\n    enddo\n  endif\nreturn a\n";
  my $*FURTHEST = 0;
  XC::Grammar.parse($src, actions => Counting.new);
  $calls == 7                                # a, 0, b, a, b, c, 2 -- it was 248
};
check 'the look-ahead skips an assignment that is not there, and a call is still a call',
{
  my $src = "user function f(a)\n  conout(a, f(a), a[1])\n  a := f(a)\n  a += 1\n  a |> tap(\{|x| x\})\nreturn a\n";
  my $*FURTHEST = 0;
  my $m = XC::Grammar.parse($src);
  my @kinds = $m<toplevel>[0]<function><funcbody><statement>.map({ .<simple>.hash.keys.grep(* ne 'modifier').sort.join });
  @kinds.join(' ') eq 'callst assignment assignment pipest returnst'
};

# XC::Source: offsets are characters already, or the text is ASCII -- nothing
# to do; otherwise each worked out once.
grammar Probe { token TOP { .*? <x> .* }; token x { 'X' } }
check 'a match offset after an accent is still the right character',
{
  my $t = "ção\nX";
  XC::Source.new(text => $t).char(Probe.parse($t)<x>.from) == 4
};
check 'and in an ASCII text, the offset as it is',
{
  my $t = "abc\nX";
  XC::Source.new(text => $t).char(Probe.parse($t)<x>.from) == 4
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
