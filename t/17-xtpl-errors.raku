use lib 'lib';
use XC::Grammar;

# The sources xtpl refuses, copied into t/errors/ (see t/errors/README.md).
# Each file is in one group:
#
#   syntax     the grammar refuses it -- and the source with its correction
#              parses, which shows the refusal was for the right error
#   analysis   the grammar accepts it; refusing it is for a pass that does
#              not exist yet
#   decided    xc accepts it on purpose, against xtpl
#   pending    it uses a construct xc cannot read yet -- shown, not counted

# file => the correction, as 'from' => 'to' pairs replaced across the text
my %syntax =
  const_no_init         => ('local nL <const>' => 'local nL <const> := 1',),
  decl_trailing_comma   => ('local nA := 1,' => 'local nA := 1',),
  defined_or_expression => ('?= {}' => '?: {}',),
  feed_in_block         => ('[x] x |> triple' => '[x] triple(x)',),
  feed_no_head          => (':= |> distinct' => ':= aNums |> distinct',),
  generated_name        => ('fo_0_0' => 'nFo',),
  interp_unclosed       => ('{"t"}' => "\{'t'\}",),
  prologue              => ("  conout(n)\n  local m := 2\n" => "  local m := 2\n  conout(n)\n",),
  reserved_word         => ('local if' => 'local nIf', 'return if' => 'return nIf'),
  stale_fold            => ('[+]a' => 'asum(a)',),
  stale_keyword         => ("  given n do\n  end given\n" => "  do case\n  case n == 1\n  endcase\n",),
  unbalanced_line       => ('minhaFuncao(nX,' => 'minhaFuncao(nX, ;',),
  unknown_attribute     => ('<bogus>' => '<const>',),
  using_unclosed        => ("    nT := 1\n" => "    nT := 1\n  end using\n",),
  ;

my @analysis = <
  arity_too_many call_form const_assign const_by_ref contained_captured
  contained_deferred distinct_adjacent_no_key external_assign fallback_over_source
  out_of_scope redeclared scalar_chain scalar_declared source_stranded
  undeclared_read undeclared_write
>;

# A bare 'function': TL++ accepts it with a 'u_' name (and maybe other
# prefixes), so xc does not refuse it -- xtpl refuses them all.
my @decided = <bare_function>;

# None at the moment; a new error case that needs an unbuilt construct goes
# here, as 'name => "the construct"'.
my %pending;

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

sub parses(Str $src) { XC::Grammar.parse($src).defined }
sub source(Str $name) { slurp("t/errors/$name.xtpl") }

# ---- syntax: refused, and the correction parses ------------------------------------
for %syntax.keys.sort -> $name
{
  my $src = source($name);
  check "syntax   $name: refused", { !parses($src) };

  my $fixed = $src;
  my $replaced = True;
  for %syntax{$name}.list -> $p
  {
    $replaced = False unless $fixed.contains($p.key);
    $fixed = $fixed.subst($p.key, $p.value, :g);
  }
  check "syntax   $name: corrected, it parses", { $replaced && parses($fixed) };
}

# ---- analysis: the grammar accepts it ------------------------------------------------
for @analysis -> $name
{
  check "analysis $name: the grammar accepts it", { parses(source($name)) };
}

# ---- decided ---------------------------------------------------------------------
for @decided -> $name
{
  check "decided  $name: accepted on purpose", { parses(source($name)) };
}

# ---- pending -----------------------------------------------------------------------
for %pending.keys.sort -> $name
{
  say "  skip   pending $name: uses %pending{$name}, which xc cannot read yet";
}

# ---- what xtpl decides, case by case ---------------------------------------------
# Each line was run on xtpl itself ('--check'), and its verdict is what is
# expected here. Several are not obvious: 'else' opens no prologue, 'begin
# sequence' is not a scope, and the generated-name shape is only refused at
# function level, the only declaration emitted with the name as written.
my @xtpl =
  # prologue
  True,  'local at the start of a while body',  "  while n > 0\n    local nY := 1\n    n := n - nY\n  enddo",
  True,  'local at the start of a for body',    "  for local i := 1 to 3\n    local nY := i\n    conout(nY)\n  next",
  True,  'private in the prologue',             "  private nP := 0\n  conout(nP)",
  False, 'local after a statement',             "  conout(1)\n  local nL := 0",
  False, 'private after a statement',           "  conout(1)\n  private nP := 0",
  False, 'local in the else body',              "  if n > 0\n    conout(1)\n  else\n    local nY := 1\n  endif",
  False, 'local in the else body, empty if',    "  if n > 0\n  else\n    local nY := 1\n  endif",
  False, 'local in the elseif body',            "  if n > 0\n    conout(1)\n  elseif n < 0\n    local nY := 1\n  endif",
  False, 'local in a case body',                "  do case\n  case n > 0\n    local nY := 1\n  endcase",
  False, 'local inside begin sequence',         "  begin sequence\n    local nY := 1\n  end sequence",
  # reserved words
  False, 'reserved as a local: if',             "  local if := 1",
  False, 'reserved as a local: len',            "  local len := 1",
  False, 'reserved in upper case: LEN',         "  local LEN := 1",
  False, 'reserved in a header: if local',      "  if local len := 1, len > 0\n  endif",
  False, 'reserved in a for local',             "  for local len := 1 to 2\n  next",
  True,  'reserved as a lambda parameter',      "  local b := map(a, [len] len + 1)",
  # generated-name shapes
  False, 'generated as a local: FO_0_0',        "  local FO_0_0 := 1",
  False, 'generated as a private: fo_0_0',      "  private fo_0_0 := 1",
  False, 'generated as a local: __x',           "  local __x := 1",
  True,  'generated in a block local',          "  if n > 0\n    local fo_0_0 := 1\n  endif",
  True,  'generated in a header: if local',     "  if local fo_0_0 := 1, fo_0_0 > 0\n  endif",
  True,  'generated in a for local',            "  for local fo_0_0 := 1 to 2\n  next",
  True,  'generated as a lambda parameter',     "  local b := map(a, [fo_0_0] fo_0_0 + 1)",
  True,  'near miss: fo_0',                     "  local fo_0 := 1",
  True,  'near miss: s_x_1',                    "  local s_x_1 := 1",
  ;

for @xtpl -> $accepts, $what, $body
{
  my $src = "user function f(n, a)\n$body\nreturn n\n";
  check "xtpl {$accepts ?? 'accepts' !! 'refuses'}: $what", { parses($src) == $accepts };
}

# Parameters have a rule of their own: a reserved word is refused, a generated
# shape is accepted.
check 'xtpl refuses: reserved as a parameter',  { !parses("user function f(if)\nreturn 1\n") };
check 'xtpl accepts: generated as a parameter', {  parses("user function f(fo_0_0)\nreturn 1\n") };

# ---- every file is in a group ---------------------------------------------------
my @all = dir('t/errors').grep(*.extension eq 'xtpl').map(*.basename.subst('.xtpl', '')).sort;
my @known = (|%syntax.keys, |@analysis, |@decided, |%pending.keys);
my @loose = @all.grep({ $_ !(elem) @known });
check "every file in t/errors/ is in a group" ~ (@loose ?? " -- no group: {@loose.join(', ')}" !! ''),
{
  !@loose
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
