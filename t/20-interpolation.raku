use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# xtpl's string interpolation: '${ expr }' inside a string. The behaviour was
# settled against xtpl's own output. Both directions: the parts that come out,
# and what has to be refused.
#
# The xtpl snippets are single-quoted Raku strings (q[...]) so that Raku does
# not try to interpolate their braces itself.

sub expr(Str $src)
{
  my $m = XC::Grammar.parse($src, rule => 'expr', actions => XC::Actions.new(source => $src));
  $m ?? $m.made !! Nil
}

sub parses(Str $src) { XC::Grammar.parse($src, rule => 'expr').defined }

# The parts, spelled out: text as [text], an expression as <Kind>.
sub parts(Interp $i)
{
  $i.parts.map({ $_ ~~ Str ?? "[$_]" !! '<' ~ .^name.subst('XC::AST::', '') ~ '>' }).join
}

sub names(Expr $e)
{
  my @n;
  walk-expr($e, { @n.push(.name) if $_ ~~ Name });
  @n.join(' ')
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# ---- the parts ----------------------------------------------------------------------
check 'text, an expression, text',
{
  my $i = expr(q["total = ${nTotal} itens"]);
  $i ~~ Interp && parts($i) eq '[total = ]<Name>[ itens]' && $i.parts[1].name eq 'nTotal'
};
check 'an Interp is still a Literal of type Character, with its text as written',
{
  my $i = expr(q["a ${n} b"]);
  $i ~~ Literal && $i.type eq 'Character' && $i.text eq q["a ${n} b"]
};
check 'single quotes interpolate too',
{
  parts(expr(q['total ${n} x'])) eq '[total ]<Name>[ x]'
};
check 'only an interpolation',
{
  parts(expr(q["${cNome}"])) eq '<Name>'
};
check 'several, and adjacent ones',
{
  parts(expr(q["${a}${b} and ${c}"])) eq '<Name><Name>[ and ]<Name>'
};
check 'a string with no ${ stays a plain Literal',
{
  my $l = expr(q["plain text"]);
  $l ~~ Literal && $l !~~ Interp
};
check 'a lone $ is text: "R$ 10" and "$n"',
{
  expr(q["R$ 10"]) !~~ Interp && expr(q["$n"]) !~~ Interp
};
check 'no escapes: a backslash is text, and ${ still interpolates',
{
  parts(expr(q["x \${n} y"])) eq '[x \\]<Name>[ y]'
};

# ---- what can go inside ------------------------------------------------------------
check 'a hash read, with the other quote: "taxa ${hCfg{\'t\'}} fim"',
{
  my $i = expr(q["taxa ${hCfg{'t'}} fim"]);
  $i.parts[1] ~~ HashIndex
};
check 'a call with arguments: "sent to ${join(aDest, \', \')}"',
{
  my $i = expr(q["sent to ${join(aDest, ', ')}"]);
  $i.parts[1] ~~ Call && $i.parts[1].args == 2
};
check 'a negation, an index and a member',
{
  expr(q["ha ${-nDias} dias"]).parts[1] ~~ Binary
    && expr(q["first ${aItens[1]:cCodigo}"]).parts[1] ~~ Member
};
check 'arithmetic: "soma ${1 + 2} fim"',
{
  expr(q["soma ${1 + 2} fim"]).parts[1] ~~ Binary
};
check 'spaces inside the braces',
{
  parts(expr(q["a ${ n } b"])) eq '[a ]<Name>[ b]'
};
check 'a nested interpolation, in the other quote',
{
  my $i = expr(q["x ${f('in ${a}')} y"]);
  $i.parts[1] ~~ Call && $i.parts[1].args[0] ~~ Interp
};
check 'names read inside an interpolation are visible to the walk',
{
  names(expr(q["${cTabela} tem ${len(aCampos)} campos"])) eq 'cTabela aCampos'
};

# ---- in statements --------------------------------------------------------------
check "in a local initializer too (xtpl leaves that one uninterpolated)",
{
  my $src = qq[user function f(n)\n  local c := "total \$\{n\}"\nreturn c\n];
  my $p = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src)).made;
  $p.functions[0].body[0].declarators[0].init ~~ Interp
};

# ---- what has to be refused -----------------------------------------------------------
my @refuse =
  q["a ${} b"]              => 'an empty ${}',
  q["x ${h{"k"}} y"]        => 'the same quote inside the expression',
  q['x ${h{'k'}} y']        => 'the same quote inside, single-quoted',
  q["x ${h{'k'} y"]         => 'an unclosed ${',
  q["x ${n + 1"]            => 'an unclosed ${, at the end',
  q["x ${n +} y"]           => 'not a valid expression inside',
  q["a ${f('b ${"c"}')} d"] => 'a quote of any enclosing string, two levels down',
  ;

for @refuse -> $c
{
  check "refuses: {$c.value}", { !parses($c.key) };
}

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
