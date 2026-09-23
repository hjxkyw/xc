use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# xtpl's operators: 'h{"k"}' and 'has', 'in', 'lo..hi', '%%', '?:', '?.',
# '?=', and the '<const>'/'<contained>' attributes. Both directions: the shape
# and precedence that come out, and what has to be refused.

sub expr(Str $src)
{
  my $m = XC::Grammar.parse($src, rule => 'expr', actions => XC::Actions.new(source => $src));
  $m ?? $m.made !! Nil
}

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

# ---- hash -----------------------------------------------------------------------
check 'hCfg{"taxa"}: a HashIndex, base and key',
{
  my $e = expr('hCfg{"taxa"}');
  $e ~~ HashIndex && $e.base.name eq 'hCfg' && $e.key ~~ Literal
};
check 'a key that is an expression: hDescricao{oItem:cProduto}',
{
  my $e = expr('hDescricao{oItem:cProduto}');
  $e.key ~~ Member && names($e) eq 'hDescricao oItem'
};
check 'as a target: hCfg{"limite"} := 2000',
{
  my $s = stmt('hCfg{"limite"} := 2000');
  $s ~~ Assignment && $s.target ~~ HashIndex
};
check 'inside arithmetic: nBase * hCfg{"taxa"}',
{
  my $e = expr('nBase * hCfg{"taxa"}');
  $e ~~ Binary && $e.op eq '*' && $e.right ~~ HashIndex
};
check 'has, and with .and.: (h has "a") .and. (h has "b")',
{
  my $e = expr('hCfg has "a" .and. hCfg has "b"');
  $e.op eq '.and.' && $e.left.op eq 'has' && $e.right.op eq 'has'
};

# ---- in and lo..hi -------------------------------------------------------------------
check 'cCod in aCodigos',
{
  my $e = expr('cCod in aCodigos');
  $e ~~ Binary && $e.op eq 'in' && $e.right.name eq 'aCodigos'
};
check 'the collection stops at .and.: (cCod in aC) .and. lOk',
{
  my $e = expr('cCod in aC .and. lOk');
  $e.op eq '.and.' && $e.left.op eq 'in'
};
check 'and at the comma: f(cCod in aCodes, nValor) has two arguments',
{
  my $e = expr('f(cCod in aCodes, nValor)');
  $e.args == 2 && $e.args[0].op eq 'in'
};
check 'the literal stays whole: n in {1, 2, 3}',
{
  expr('n in {1, 2, 3}').right ~~ ArrayLit
};
check 'nValor in 1..100: the interval on the right',
{
  my $e = expr('nValor in 1..100');
  $e.op eq 'in' && $e.right ~~ Interval && $e.right.lo.text eq '1' && $e.right.hi.text eq '100'
};
check '1..999 |> asum: an interval as the source',
{
  my $e = expr('1..999 |> asum');
  $e ~~ Pipeline && $e.source ~~ Interval
};
check 'ends with arithmetic: n in a + 1..b - 1',
{
  my $i = expr('n in a + 1..b - 1').right;
  $i ~~ Interval && $i.lo ~~ Binary && $i.hi ~~ Binary
};
check 'index and inList are names, not the in operator',
{
  expr('index') ~~ Name && expr('f(inList)').args[0].name eq 'inList'
};

# ---- %% ----------------------------------------------------------------------------
check '(nX * 2) %% 2',
{
  my $e = expr('(nX * 2) %% 2');
  $e.op eq '%%' && $e.left.op eq '*'
};
check 'a %% 3 .or. a %% 5: tighter than .or.',
{
  my $e = expr('a %% 3 .or. a %% 5');
  $e.op eq '.or.' && $e.left.op eq '%%' && $e.right.op eq '%%'
};
check "AdvPL's % is still %",
{
  expr('5 % 2').op eq '%'
};

# ---- ?: and ?. -------------------------------------------------------------------------
check 'a ?: b ?: c chains to the right',
{
  my $e = expr('a ?: b ?: c');
  $e.op eq '?:' && $e.left.name eq 'a' && $e.right.op eq '?:'
};
check '?: is looser than .or.',
{
  my $e = expr('a .or. b ?: c');
  $e.op eq '?:' && $e.left.op eq '.or.'
};
check '?: is tighter than |>',
{
  my $e = expr('f() ?: {} |> tap([x] x)');
  $e ~~ Pipeline && $e.source.op eq '?:'
};
check 'oP?.oC?.cNome: two safe links',
{
  my $e = expr('oP?.oC?.cNome');
  $e ~~ SafeMember && $e.name eq 'cNome' && $e.base ~~ SafeMember
    && $e.base.base.name eq 'oP'
};
check 'a SafeMember is still a Member',
{
  expr('o?.x') ~~ Member
};
check 'oUser?.cCity ?: "x"',
{
  my $e = expr('oUser?.cCity ?: "x"');
  $e.op eq '?:' && $e.left ~~ SafeMember
};

# ---- ?= -----------------------------------------------------------------------------
check 'cCache ?= "vazio": an Assignment with op ?=',
{
  my $s = stmt('cCache ?= "vazio"');
  $s ~~ Assignment && $s.op eq '?=' && $s.target.name eq 'cCache'
};
check '?= with a modifier',
{
  my $s = stmt('nX ?= 3 if lReset');
  $s ~~ Modified && $s.stmt.op eq '?='
};

# ---- attributes ---------------------------------------------------------------------------
check 'local v1 <const, contained> := 0, v2 := 1',
{
  my $d = stmt('local v1 <const, contained> := 0, v2 := 1');
  $d.declarators[0].attributes.join(',') eq 'const,contained' && !$d.declarators[1].attributes
};
check 'local v5<const>:=3, no spaces at all',
{
  stmt('local v5<const>:=3').declarators[0].attributes.join eq 'const'
};
check 'local aW <contained>, no value',
{
  my $d = stmt('local aW <contained>').declarators[0];
  $d.attributes.join eq 'contained' && !$d.init.defined
};
check 'an attribute with a type: local n <const> := 1 as N',
{
  my $d = stmt('local n <const> := 1 as N').declarators[0];
  $d.attributes.join eq 'const' && $d.declared eq 'Numeric'
};

# ---- what has to be refused -----------------------------------------------------------
my @refuse =
  'x := hCfg {"taxa"}'        => 'a space between the name and {',
  'x := h{"a"}{"b"}'          => 'a hash of a hash',
  'x := 1..10'                => 'a loose interval',
  'x := f(1..10)'             => 'an interval as an argument',
  'x := (f() ?= 1)'           => '?= in an expression',
  'local x ?= 1'              => '?= in a declaration',
  'local x <const>'           => 'const with no value',
  'local x <const> as N'      => 'const with no value, with a type',
  'local x <frozen> := 1'     => 'an attribute that does not exist',
  'local x <> := 1'           => 'an empty attribute',
  'x := o?.M()'               => '?. with a call',
  'x := a ?:'                 => '?: with no right side',
  'x := a in'                 => 'in with no collection',
  'x := n %%'                 => '%% with no right side',
  ;

for @refuse -> $c
{
  check "refuses: {$c.value} ({$c.key})", { !parses($c.key) };
}

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
