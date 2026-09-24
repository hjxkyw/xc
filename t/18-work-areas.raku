use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# xtpl's work-area constructs: 'using alias ... end using' and 'external'.
# The edge cases were run on xtpl itself ('--check'). Both directions: the
# shape that comes out, and what has to be refused.

sub program(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? $m.made !! Nil
}

sub body(Str $lines)
{
  my $p = program("user function f(nOrd)\n$lines\nreturn 1\n");
  $p ?? $p.functions[0].body !! Nil
}

sub parses(Str $src) { XC::Grammar.parse($src).defined }
sub body-parses(Str $lines) { parses("user function f(nOrd)\n$lines\nreturn 1\n") }

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# ---- using alias --------------------------------------------------------------
check 'using alias SA1 order 1 do: area, order and body',
{
  my $u = body("  using alias SA1 order 1 do\n    nT := SA1->A1_SALDO\n    conout(nT)\n  end using")[0];
  $u ~~ UsingAlias && $u.area eq 'SA1' && $u.order ~~ Literal && $u.order.text eq '1'
    && $u.body == 2
};
check 'without order: order undefined',
{
  !body("  using alias SA1 do\n    conout(1)\n  end using")[0].order.defined
};
check 'order is an expression: order nOrd',
{
  body("  using alias SA1 order nOrd do\n    conout(1)\n  end using")[0].order ~~ Name
};
check 'a variable holding the alias: the word is kept as written',
{
  body("  using alias cAlias do\n    conout(1)\n  end using")[0].area eq 'cAlias'
};
check 'an early return inside the block',
{
  my $u = body("  using alias SA1 do\n    return nT if nT > 100\n  end using")[0];
  $u.body[0] ~~ Modified && $u.body[0].stmt ~~ ReturnStmt
};
check 'nested blocks',
{
  my $u = body("  using alias SA1 do\n    using alias SB1 order 1 do\n      conout(1)\n    end using\n  end using")[0];
  $u.area eq 'SA1' && $u.body[0] ~~ UsingAlias && $u.body[0].area eq 'SB1'
};
check 'the body opens a prologue: a local at its start',
{
  my $u = body("  using alias SA1 do\n    local nX := SA1->A1_SALDO\n    conout(nX)\n  end using")[0];
  $u.body[0] ~~ Declaration
};
check 'walk goes into the body; exprs-of gives the order',
{
  my $u = body("  using alias SA1 order nOrd do\n    conout(nA)\n  end using")[0];
  my @seen;
  walk(($u,), { @seen.push(.^name.subst('XC::AST::', '')) });
  my @n;
  walk-expr($_, { @n.push(.name) if $_ ~~ Name }) for exprs-of($u);
  @seen.join(' ') eq 'UsingAlias CallStmt' && @n.join eq 'nOrd'
};

# ---- external -------------------------------------------------------------------
my $ext = program(qq:to/END/);
#include "totvs.ch"
external CRLF, dDataBase
external alias SA1, SB1              // the caller opens these
user function f()
  conout(CRLF)
return 1
END

check 'external CRLF, dDataBase: names, not an alias, with its line',
{
  my $e = $ext.externals[0];
  $e ~~ External && !$e.alias && $e.names.join(',') eq 'CRLF,dDataBase' && $e.line == 2
};
check 'external alias SA1, SB1: work areas',
{
  my $e = $ext.externals[1];
  $e.alias && $e.names.join(',') eq 'SA1,SB1'
};
check 'the function after them is untouched',
{
  $ext.functions == 1 && $ext.directives == 1
};
check 'external aliasX: a name that merely starts with alias',
{
  my $e = program("external aliasX\nuser function f()\nreturn 1\n").externals[0];
  !$e.alias && $e.names.join eq 'aliasX'
};

# ---- what has to be refused -----------------------------------------------------------
my @refuse-body =
  "  using alias SA1 do\n    conout(1)\n  endusing"   => 'using closed by endusing',
  "  using alias SA1 do\n    conout(1)\n  end"        => 'using closed by a bare end',
  "  using alias SA1 do\n    conout(1)"               => 'using never closed',
  "  using alias SA1\n    conout(1)\n  end using"     => "using without 'do'",
  "  using SA1 do\n    conout(1)\n  end using"        => "using without 'alias'",
  "  using alias do\n    conout(1)\n  end using"      => 'using alias with no name',
  "  using alias SA1 order do\n  end using"           => 'order with no expression',
  "  using alias SA1 do\n    conout(1)\n    local nX := 1\n  end using"
                                                      => 'a local after a statement in the body',
  ;

for @refuse-body -> $c
{
  check "refuses: {$c.value}", { !body-parses($c.key) };
}

# The doc's rule, and all of xtpl's corpus: file level, at least one name.
# xtpl itself is laxer on both, and xc follows the doc.
my @refuse-file =
  "external\nuser function f()\nreturn 1\n"                   => 'external with no names',
  "external alias\nuser function f()\nreturn 1\n"             => 'external alias with no names',
  "external CRLF,\nuser function f()\nreturn 1\n"             => 'external with a trailing comma',
  "user function f()\n  external CRLF\nreturn 1\n"            => 'external inside a function',
  ;

for @refuse-file -> $c
{
  check "refuses: {$c.value}", { !parses($c.key) };
}

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
