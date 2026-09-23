use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# xtpl's postfix modifiers: 'x := 1 if c', 'return n if c', 'f() while c',
# 'exec f() if c'. The cases come from xtpl's tests and examples. Both
# directions: the shape that comes out, and what has to be refused.
#
# 'return(x) if c' is here on purpose: it is the case xtpl's fuzz_paths.py
# found -- right on one of xtpl's paths and wrong on the other, and no fixed
# test covered it.

sub stmt(Str $line)
{
  my $src = "user function f()\n  $line\nreturn\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? $m.made.functions[0].body[0] !! Nil
}

sub parses(Str $line)
{
  XC::Grammar.parse("user function f()\n  $line\nreturn\n").defined
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# ---- return ---------------------------------------------------------------------
check 'return if lSkip: no value -- the if is not the value',
{
  my $s = stmt('return if lSkip');
  $s ~~ Modified && $s.op eq 'if' && $s.stmt ~~ ReturnStmt && !$s.stmt.value.defined
    && $s.cond ~~ Name && $s.cond.name eq 'lSkip'
};
check 'return nTotal if nTotal > 100',
{
  my $s = stmt('return nTotal if nTotal > 100');
  $s.stmt ~~ ReturnStmt && $s.stmt.value.name eq 'nTotal' && $s.cond ~~ Binary
};
check 'return(nTotal) if nX > 100: touching the (, and still a return',
{
  my $s = stmt('return(nTotal) if nX > 100');
  $s ~~ Modified && $s.stmt ~~ ReturnStmt && $s.stmt.value.name eq 'nTotal'
};
check 'return {} if !lOk: a literal as the value',
{
  my $s = stmt('return {} if !lOk');
  $s.stmt.value ~~ ArrayLit && $s.cond ~~ Binary
};
check 'return without a modifier is still a ReturnStmt',
{
  my $s = stmt('return nX');
  $s ~~ ReturnStmt && $s.value.name eq 'nX'
};

# ---- the other simple statements ---------------------------------------------------
check 'lDone := .T. if nTotal > 5: assignment',
{
  my $s = stmt('lDone := .T. if nTotal > 5');
  $s ~~ Modified && $s.stmt ~~ Assignment && $s.stmt.target.name eq 'lDone'
};
check 'exec resetAll() if nTotal == 0: the expression becomes a statement',
{
  my $s = stmt('exec resetAll() if nTotal == 0');
  $s ~~ Modified && $s.op eq 'if' && $s.stmt ~~ CallStmt
    && $s.stmt.call.name eq 'resetAll'
};
check 'conout("x") while nTotal < 0: op while',
{
  my $s = stmt('conout("x") while nTotal < 0');
  $s.op eq 'while' && $s.stmt ~~ CallStmt
};
check 'exit if nErros > 3, and loop if empty(...)',
{
  stmt('exit if nErros > 3').stmt ~~ ExitStmt
    && stmt('loop if empty(oItem:cCodigo)').stmt ~~ LoopStmt
};
check 'a method as a statement: oObj:Salva() if lOk',
{
  my $s = stmt('oObj:Salva() if lOk');
  $s.stmt ~~ CallStmt && $s.stmt.call ~~ MethodCall
};
check 'a work-area field in the condition: nT := 1 if SA1->A1_SALDO == "abc"',
{
  my $s = stmt('nT := 1 if SA1->A1_SALDO == "abc"');
  $s.cond ~~ Binary && $s.cond.left ~~ AliasField
};
check 'a comment at the end of the line',
{
  stmt('exit if nX == 0   // not a block word').stmt ~~ ExitStmt
};

# ---- words that merely start with if/while -------------------------------------------
check 'iif(...) is not a modifier',
{
  my $s = stmt('x := iif(a, b, c)');
  $s ~~ Assignment && $s.value ~~ Call && $s.value.name eq 'iif'
};
check 'iif(...) followed by a real modifier',
{
  my $s = stmt('x := iif(a, b, c) if d');
  $s ~~ Modified && $s.stmt.value.name eq 'iif' && $s.cond.name eq 'd'
};
check 'x := ifood: a variable starting with if',
{
  my $s = stmt('x := ifood');
  $s ~~ Assignment && $s.value.name eq 'ifood'
};
check 'x := 1 if ifood: a condition starting with if',
{
  stmt('x := 1 if ifood').cond.name eq 'ifood'
};

# ---- walking ---------------------------------------------------------------------
check 'walk visits the Modified and the statement inside',
{
  my @seen;
  walk((stmt('x := nA if nB'),), { @seen.push(.^name.subst('XC::AST::', '')) });
  @seen.join(' ') eq 'Modified Assignment'
};
check 'exprs-of a Modified is the condition',
{
  my @n;
  walk-expr($_, { @n.push(.name) if $_ ~~ Name }) for exprs-of(stmt('x := nA if nB > nC'));
  @n.join(' ') eq 'nB nC'
};

# ---- what has to be refused -----------------------------------------------------------
my @refuse =
  'exec resetAll()'           => 'exec without a modifier',
  'local x := 1 if c'         => 'a declaration with a modifier',
  'if x if y'                 => 'a block if with a modifier',
  'x := 1 if'                 => 'a modifier with no condition',
  'return if'                 => 'return with a modifier and no condition',
  'x := 1 if a if b'          => 'two modifiers',
  'x := 1 unless c'           => 'unless does not exist',
  ;

for @refuse -> $c
{
  check "refuses: {$c.value} ({$c.key})", { !parses($c.key) };
}

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
