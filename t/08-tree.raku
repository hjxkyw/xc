use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# The tree of the statements. Both directions, as in 07: the shape that has to
# come out, and what has to be refused. Several cases here were accepted with
# the wrong shape when a line break was plain whitespace -- a 'return' with no
# value took the next line, and the next function's 'user'.

sub tree(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? $m.made !! Nil
}

# A bare body, inside a function that does nothing else.
sub body(Str $lines)
{
  my $p = tree("user function f()\n" ~ $lines ~ "\n");
  $p ?? $p.functions[0].body !! Nil
}

sub kinds(@s) { @s.map(*.^name.subst('XC::AST::', '')).join(' ') }

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# ---- the reference file --------------------------------------------------------
my $p = tree(slurp('examples/saldo.xtpl'));

check 'saldo.xtpl: namespace, using, include',
{
  $p.namespace eq 'exemplo.saldo' && $p.usings eqv ['tlpp.regex']
    && $p.directives eqv ['#include "totvs.ch"']
};
check 'saldo.xtpl: one user function, on line 20',
{
  $p.functions == 1 && $p.functions[0].type eq 'user'
    && $p.functions[0].name eq 'saldo' && $p.functions[0].line == 20
};
check 'saldo.xtpl: the annotation sits on the function, not loose',
{
  $p.functions[0].annotations.map(*.name).List eqv ('Get',) && !$p.annotations
};
check 'saldo.xtpl: typed parameters, abbreviation expanded',
{
  $p.functions[0].params.map({ .name ~ ':' ~ .declared }).join(' ')
    eq 'cCliente:Character nLimite:Numeric'
};
check 'saldo.xtpl: the statements of the body, in order',
{
  kinds($p.functions[0].body) eq
    'Declaration Declaration Declaration Declaration Declaration IfStmt Assignment '
    ~ 'ForStmt CaseStmt SequenceStmt ReturnStmt'
};
check 'saldo.xtpl: walk goes into everything, in reading order',
{
  my @seen;
  walk($p.functions[0].body, { @seen.push($_) });
  kinds(@seen.grep({ $_ !~~ Declaration })) eq
    'IfStmt ReturnStmt Assignment ForStmt IfStmt LoopStmt Assignment IfStmt ExitStmt CaseStmt '
    ~ 'CallStmt CallStmt CallStmt SequenceStmt Assignment Assignment ReturnStmt'
};
check 'saldo.xtpl: the last return is on line 63 and returns nTotal',
{
  my $r = $p.functions[0].body[*-1];
  $r ~~ ReturnStmt && $r.line == 63 && $r.value ~~ Name && $r.value.name eq 'nTotal'
};

# ---- the shape of each statement -----------------------------------------------
check 'if / elseif / elseif / else: three branches and an otherwise',
{
  my @s = body("  if a\n    x()\n  elseif b\n    y()\n  elseif c\n    z()\n  else\n    w()\n  endif");
  @s == 1 && @s[0].branches == 3 && @s[0].otherwise == 1
    && @s[0].branches.map({ .cond.name }).join eq 'abc'
};
check 'if without else: empty otherwise, and the next statement stays outside',
{
  my @s = body("  if a\n    x()\n  endif\n  y()");
  kinds(@s) eq 'IfStmt CallStmt' && !@s[0].otherwise && @s[0].branches[0].body == 1
};
check 'do case: the cases as branches, otherwise as otherwise',
{
  my @s = body("  do case\n  case a\n    x()\n  case b\n  otherwise\n    y()\n    z()\n  endcase");
  @s[0] ~~ CaseStmt && @s[0].branches == 2 && !@s[0].branches[1].body && @s[0].otherwise == 2
};
check 'for with step: var, from, to and step',
{
  my $f = body("  for i := 10 to 1 step -1\n    x()\n  next i")[0];
  $f ~~ ForStmt && $f.var eq 'i' && $f.from.text eq '10' && $f.step.defined
    && $f.body == 1
};
check 'for without step: step undefined',
{
  !body("  for i := 1 to n\n  next")[0].step.defined
};
check 'while with exit and loop inside an if',
{
  my $w = body("  while a\n    if b\n      exit\n    endif\n    loop\n  enddo")[0];
  $w ~~ WhileStmt && kinds($w.body) eq 'IfStmt LoopStmt'
    && kinds($w.body[0].branches[0].body) eq 'ExitStmt'
};
check 'begin sequence ... recover using oErr',
{
  my $s = body("  begin sequence\n    x()\n  recover using oErr\n    y()\n  end sequence")[0];
  $s ~~ SequenceStmt && $s.has-recover && $s.error-var eq 'oErr' && $s.recover == 1
};
check 'begin sequence without recover',
{
  my $s = body("  begin sequence\n    x()\n  end")[0];
  !$s.has-recover && !$s.error-var.defined && !$s.recover
};
check 'assignment: op, and a target with a trailer becomes the chain',
{
  my @s = body("  n += 1\n  oObj:nX := 2\n  a[i] := 3");
  @s[0].op eq '+=' && @s[0].target ~~ Name
    && @s[1].target ~~ Member && @s[1].target.base.name eq 'oObj'
    && @s[2].target ~~ Index && @s[2].target.indices[0].name eq 'i'
};
check 'call as a statement: of a function and of a method',
{
  my @s = body("  conout(\"a\", 1)\n  oDlg:Activate()");
  @s[0].call ~~ Call && @s[0].call.args == 2
    && @s[1].call ~~ MethodCall && @s[1].call.name eq 'Activate'
};
check 'an annotation with no function after it stays in the program',
{
  my $q = tree("@Deprecated\n#define X 1\n");
  $q.annotations.map(*.name).List eqv ('Deprecated',) && !$q.functions
};

# ---- where the line ends ---------------------------------------------------------
check 'return without a value does not take the next line',
{
  my @s = body("  return\n  conout(1)");
  kinds(@s) eq 'ReturnStmt CallStmt' && !@s[0].value.defined
};
check 'return without a value inside an if',
{
  my @s = body("  if x\n    return\n  endif\n  return 1");
  kinds(@s) eq 'IfStmt ReturnStmt' && !@s[0].branches[0].body[0].value.defined
};
check "a return at the end does not take the next function's 'user'",
{
  my $q = tree("user function f()\n  return\n\nuser function g()\n  return\n");
  $q.functions.map({ .type ~ ' ' ~ .name }).join(', ') eq 'user f, user g'
};
check 'two static functions in a row',
{
  tree("static function f()\n  return 1\nstatic function g()\n  return 2\n")
    .functions.map(*.type).join(' ') eq 'static static'
};
check "next without a name does not take the next line",
{
  kinds(body("  for i := 1 to 3\n  next\n  do case\n  case a\n  endcase")) eq 'ForStmt CaseStmt'
};
check "';' at the end continues the statement",
{
  my @s = body("  n := soma(1, ;\n           2)\n  return n");
  kinds(@s) eq 'Assignment ReturnStmt' && @s[0].value.args == 2
};
check "';' followed by a // comment still continues",
{
  my @s = body("  aBig := aNums ;   // a comment on a continued line\n    |> distinct\n  return aBig");
  kinds(@s) eq 'Assignment ReturnStmt' && @s[0].value ~~ Pipeline
};
check "';' followed by a /* */ comment still continues",
{
  my @s = body("  n := soma(1, ; /* note */\n           2)\n  return n");
  kinds(@s) eq 'Assignment ReturnStmt' && @s[0].value.args == 2
};
check 'comments and blank lines do not become statements',
{
  kinds(body("  // so isto\n\n  n := 1 // no fim\n  /* dois\n  */\n  return n"))
    eq 'Assignment ReturnStmt'
};
check 'CRLF line endings',
{
  kinds(body("  n := 1\r\n  return n\r")) eq 'Assignment ReturnStmt'
};

# ---- what has to be refused -----------------------------------------------------------
my @refuse =
  "  n := 1  m := 2"                   => 'two statements on one line',
  "  if x n := 1 endif"                => 'a whole if on one line',
  "  n := 1\n  -1"                     => 'an expression continued without ;',
  "  if x\n    y()"                    => 'if without endif',
  "  for i := 1 to 3\n    y()"         => 'for without next',
  "  local nX as Numeric := 1 as N"    => 'type twice, in a body',
  "  n := soma(1, // ;\n    2)"         => "a ';' inside a comment is not a continuation",
  ;

for @refuse -> $c
{
  check "refuses: {$c.value}", { !body($c.key).defined };
}

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
