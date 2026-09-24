use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# xtpl's 'with object ... end with' and 'raw'. The edge cases were run on xtpl
# itself, and its output read: where xtpl accepts a form but emits code that is
# not AdvPL (a bare 'end', a stray ':x', 'endraw', 'raw := 2'), xc refuses it or
# reads it as what it has to be. Both directions: the shape that comes out, and
# what has to be refused.

sub body(Str $lines)
{
  my $src = "user function f(o, p, a, n)\n$lines\nreturn 1\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? $m.made.functions[0].body !! Nil
}

sub parses(Str $lines)
{
  XC::Grammar.parse("user function f(o, p, a, n)\n$lines\nreturn 1\n").defined
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

# ---- with object ------------------------------------------------------------------
check 'with object: the subject and the body',
{
  my $w = body(q:to/END/.chomp)[0];
    with object oModel:GetModel("SA1DETAIL")
      :SetValue("A1_COD", cCod)
      :SetValue("A1_NOME", cNome)
    end with
  END
  $w ~~ WithObject && $w.subject ~~ MethodCall && $w.subject.name eq 'GetModel'
    && kinds($w.body) eq 'CallStmt CallStmt'
};
check ':SetValue(...) as a statement: a method on the subject',
{
  my $c = body("  with object o\n    :SetValue(\"A\", 1)\n  end with")[0].body[0];
  $c.call ~~ MethodCall && $c.call.base ~~ SubjectRef && $c.call.name eq 'SetValue'
};
check ':GetValue(...) and :cRazao in an expression',
{
  my $a = body("  with object o\n    cN := :GetValue(\"B\") + :cRazao\n  end with")[0].body[0];
  $a.value ~~ Binary && $a.value.left ~~ MethodCall && $a.value.left.base ~~ SubjectRef
    && $a.value.right ~~ Member && $a.value.right.base ~~ SubjectRef
};
check ':cNome := x: a member of the subject as a target',
{
  my $a = body("  with object o\n    :cNome := \"z\"\n  end with")[0].body[0];
  $a ~~ Assignment && $a.target ~~ Member && $a.target.base ~~ SubjectRef
};
check 'inside a call argument: len(:GetValue("A1_COD"))',
{
  my $a = body("  with object o\n    nT := len(:GetValue(\"A1_COD\"))\n  end with")[0].body[0];
  $a.value.args[0].base ~~ SubjectRef
};
check 'a : after a name stays ordinary member access',
{
  my $a = body("  with object o\n    cN := oOther:cNome\n  end with")[0].body[0];
  $a.value ~~ Member && $a.value.base ~~ Name
};
check 'inside an if inside the with, and inside a lambda',
{
  my $w = body("  with object o\n    if n > 0\n      :Ativa()\n    endif\n    a := map(a, [x] :GetValue(x))\n  end with")[0];
  $w.body[0].branches[0].body[0].call.base ~~ SubjectRef
    && $w.body[1].value.args[1].body[0].base ~~ SubjectRef
};
check 'nested blocks, each with its own subject',
{
  my $w = body("  with object o\n    with object p\n      :Ativa()\n    end with\n    :Ativa()\n  end with")[0];
  $w.subject.name eq 'o' && $w.body[0] ~~ WithObject && $w.body[0].subject.name eq 'p'
};
check 'the body opens a prologue: a local at its start',
{
  body("  with object o\n    local nX := :GetValue(\"A\")\n    conout(nX)\n  end with")[0].body[0] ~~ Declaration
};
check 'walk goes into the body; exprs-of gives the subject',
{
  my $w = body("  with object oM\n    :Ativa()\n  end with")[0];
  my @seen;
  walk(($w,), { @seen.push(.^name.subst('XC::AST::', '')) });
  my @n;
  walk-expr($_, { @n.push(.name) if $_ ~~ Name }) for exprs-of($w);
  @seen.join(' ') eq 'WithObject CallStmt' && @n.join eq 'oM'
};

# ---- raw --------------------------------------------------------------------------
check 'a raw line: the text after raw, as written',
{
  my $r = body("  raw MOSTRE cValToChar(nTotal) QUANDO nTotal > 0")[0];
  $r ~~ RawStmt && !$r.block && $r.lines == 1
    && $r.lines[0] eq 'MOSTRE cValToChar(nTotal) QUANDO nTotal > 0'
};
check 'a raw block: its lines, as written',
{
  my $r = body("  raw\n    ANOTE \"primeira\"\n    ANOTE \"segunda\"\n  end raw")[0];
  $r.block && $r.lines.map(*.trim).join(' | ') eq 'ANOTE "primeira" | ANOTE "segunda"'
};
check 'an empty raw block',
{
  my $r = body("  raw\n  end raw")[0];
  $r.block && !$r.lines
};
check 'a raw line keeps its ${...} for the lowering to interpolate',
{
  body(q[  raw ANOTE "total ${nTotal} agora"])[0].lines[0] eq q[ANOTE "total ${nTotal} agora"]
};
check "a raw line carries on over a ';' continuation",
{
  my $r = body("  raw @ 1, 1 SAY \"x\" ;\n      GET cN\n  conout(1)");
  $r[0] ~~ RawStmt && $r[0].lines[0].contains('GET cN') && $r[1] ~~ CallStmt
};
check 'raw closes the prologue: it is a statement',
{
  !parses("  raw ANOTE \"x\"\n  local nL := 1")
};
check 'raw(1) is a call, and raw := 2 an assignment to a variable named raw',
{
  my @s = body("  raw(1)\n  raw := 2");
  @s[0] ~~ CallStmt && @s[0].call ~~ Call && @s[1] ~~ Assignment && @s[1].target.name eq 'raw'
};
check 'raw as a variable name: local raw := 1',
{
  body("  local raw := 1")[0] ~~ Declaration
};

# ---- what has to be refused -----------------------------------------------------------
my @refuse =
  "  with object o\n    :Ativa()\n  endwith"                     => 'with closed by endwith',
  "  with object o\n    :Ativa()\n  end"                         => 'with closed by a bare end (xtpl emits a stray end)',
  "  with o\n    :Ativa()\n  end with"                           => "with without 'object' (a removed construct)",
  "  with object\n    :Ativa()\n  end with"                      => 'with object, no subject',
  "  with object o\n    :Ativa()"                               => 'with never closed',
  "  :Ativa()"                                                 => ':x outside a with block (xtpl emits it as is)',
  "  cN := :GetValue(\"A\")"                                    => ':x in an expression outside a with block',
  "  with object o\n    :Ativa()\n    local n := 1\n  end with" => 'a local after a statement in the body',
  "  raw\n    @ 1, 1 SAY \"x\"\n  endraw"                      => 'a raw block closed by endraw',
  "  raw\n    @ 1, 1 SAY \"x\""                                => 'a raw block never closed',
  ;

for @refuse -> $c
{
  check "refuses: {$c.value}", { !parses($c.key) };
}

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
