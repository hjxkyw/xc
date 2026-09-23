use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# Block declarations in the header -- TL++'s 'local' reused, in the position
# xtpl adds: 'for local i', 'if local x := f(), cond', 'while local ..., cond',
# 'do case with local x := f()'. And both directions: what comes out, and what
# the same position must NOT accept.
#
# A declaration in the BODY of a block ('if cond' with a 'local' inside) is
# already an ordinary statement; what is new here is the declaration in the
# header.

sub body(Str $lines)
{
  my $src = "user function f()\n" ~ $lines ~ "\n";
  my $p = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $p ?? $p.made.functions[0].body !! Nil
}

sub parses(Str $lines)
{
  XC::Grammar.parse("user function f()\n" ~ $lines ~ "\nreturn").defined
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# ---- for local ------------------------------------------------------------------
check 'for local i: var-local set, and the variable is i',
{
  my $f = body("  for local i := 1 to 3\n  next")[0];
  $f ~~ ForStmt && $f.var eq 'i' && $f.var-local
};
check 'for i without local: var-local false',
{
  !body("  for i := 1 to 3\n  next")[0].var-local
};
check 'for local i with step and a body',
{
  my $f = body("  for local i := 1 to 10 step 2\n    x()\n  next i")[0];
  $f.var-local && $f.step.defined && $f.body == 1
};
check 'for localVar: a variable that only starts with "local"',
{
  my $f = body("  for localVar := 1 to 3\n  next")[0];
  $f ~~ ForStmt && $f.var eq 'localVar' && !$f.var-local
};

# ---- if local ..., cond ----------------------------------------------------------
check 'if local x := f(), cond: a declarator in the header, then the condition',
{
  my $s = body("  if local x := f(), x > 0\n    y()\n  endif")[0];
  $s ~~ IfStmt && $s.header-decl.defined && $s.header-decl.name eq 'x'
    && $s.header-decl.init ~~ Call
    && $s.branches[0].cond ~~ Binary && $s.branches[0].body == 1
};
check 'if without local: header-decl undefined',
{
  !body("  if x > 0\n  endif")[0].header-decl.defined
};
check 'if local: the initializer and the condition are in exprs-of',
{
  my $s = body("  if local x := leExpr(nA), x > nB\n  endif")[0];
  my @names;
  walk-expr($_, { @names.push(.name) if $_ ~~ Name }) for exprs-of($s);
  # 'leExpr' is a call name (a Str), not a read; 'x' appears in the condition.
  # The 'x' the declarator writes is not an expression -- it is header-decl.name.
  @names.sort.join(' ') eq 'nA nB x'
};
check 'if local with a type on the declarator',
{
  my $s = body("  if local nX := f() as Numeric, nX > 0\n  endif")[0];
  $s.header-decl.declared eq 'Numeric'
};

# ---- while local ..., cond -------------------------------------------------------
check 'while local x := f(), cond',
{
  my $w = body("  while local x := prox(), x != Nil\n    usa(x)\n  enddo")[0];
  $w ~~ WhileStmt && $w.header-decl.defined && $w.header-decl.name eq 'x'
    && $w.cond ~~ Binary && $w.body == 1
};
check 'while without local: header-decl undefined',
{
  !body("  while x < 10\n  enddo")[0].header-decl.defined
};

# ---- do case with ----------------------------------------------------------------
check 'do case with local nS := f(): the subject is a declarator',
{
  my $c = body("  do case with local nS := calc(n)\n  case nS == 1\n    a()\n  endcase")[0];
  $c ~~ CaseStmt && $c.subject-decl.defined && $c.subject-decl.name eq 'nS'
    && !$c.subject-assign.defined && $c.branches == 1
};
check 'do case with nOther := f(): the subject is an assignment',
{
  my $c = body("  do case with nOutro := calc(n)\n  case nOutro > 3\n  endcase")[0];
  $c.subject-assign.defined && $c.subject-assign.target.name eq 'nOutro'
    && !$c.subject-decl.defined
};
check 'do case without with: no subject',
{
  my $c = body("  do case\n  case x == 1\n  otherwise\n    y()\n  endcase")[0];
  !$c.subject-decl.defined && !$c.subject-assign.defined && $c.otherwise == 1
};
check 'do case with: the subject is in exprs-of',
{
  my $c = body("  do case with local nS := soma(nA, nB)\n  case nS == 0\n  endcase")[0];
  my @names;
  walk-expr($_, { @names.push(.name) if $_ ~~ Name }) for exprs-of($c);
  @names.sort.join(' ') eq 'nA nB nS'   # 'soma' is a call name, not a read
};

# ---- what has to be refused -----------------------------------------------------------
my @refuse =
  "  if local x := f()\n  endif"          => 'if local without the condition',
  "  if local x, y > 0\n  endif"          => 'if local without an initializer',
  "  while local x := f()\n  enddo"       => 'while local without the condition',
  "  for local := 1 to 3\n  next"         => 'for local without the name',
  "  do case with\n  case x\n  endcase"   => 'do case with, without a subject',
  ;

for @refuse -> $c
{
  check "refuses: {$c.value}", { !parses($c.key) };
}

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
