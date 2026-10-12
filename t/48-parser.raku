use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;
use XC::Commands;
use XC::Parser;

# XC::Parser reads what XC::Grammar reads, by hand -- for now the
# expressions. Here every expression the grammar makes in a source -- each
# value, condition, target, call made a statement, chain run for its effect
# -- is read again by the parser at the same offset, as the same form, and
# the two trees have to be the same: every node, every attribute, every span.
# The sources: some made for the purpose, xtpl's corpus and its examples, and
# xc's self-test. (Off the repository, 889 real sources were compared so:
# 99,135 expressions, all the same.)

# Every attribute of a tree, spans and all, as text.
sub dump($x, %seen, Int $depth = 0 --> Str)
{
  return '<deep>' if $depth > 400;
  return 'Nil' unless $x.defined;
  given $x
  {
    when Str  { return $x.raku }
    when Int | Num | Rat | Bool { return ~$x }
    when Positional  { return '[' ~ $x.list.map({ dump($_, %seen, $depth + 1) }).join(', ') ~ ']' }
    when Associative { return '{' ~ $x.keys.sort.map({ "$_: " ~ dump($x{$_}, %seen, $depth + 1) }).join(', ') ~ '}' }
  }
  my $id = $x.WHICH.Str;
  return "<cycle {$x.^name}>" if %seen{$id};
  %seen{$id} = True;
  my @parts;
  for $x.^attributes -> $a
  {
    next if $a.name.starts-with('$!memo-');
    @parts.push($a.name.substr(2) ~ '=' ~ dump($a.get_value($x), %seen, $depth + 1));
  }
  %seen{$id}:delete;
  $x.^name ~ '(' ~ @parts.join(', ') ~ ')'
}

# The expressions of a body: [node, form, inside 'with object'].
sub roots(@body, Bool $with, @out, Str $src)
{
  stmt-roots($_, $with, @out, $src) for @body;
}

sub add(@out, $e, Str $form, Bool $with)
{
  @out.push([$e, $form, $with]) if $e.defined && $e.src-from >= 0;
}

sub stmt-roots($s, Bool $with, @out, Str $src)
{
  given $s
  {
    when Declaration
    {
      for .declarators -> $d
      {
        add(@out, $d.init, $d.type-first ?? 'guardexpr' !! 'value', $with);
        add(@out, $_, 'expr', $with) for $d.dims;
      }
    }
    when Assignment
    {
      add(@out, .target, 'lvalue', $with);
      add(@out, .value, .op eq '?=' ?? 'expr' !! 'value', $with);
    }
    when DefaultStmt
    {
      for .pairs -> $p
      {
        add(@out, $p.target, 'lvalue', $with);
        add(@out, $p.value, 'guardexpr', $with);
      }
    }
    when CallStmt
    {
      # Not AdvPL's 'If( c, a, b )' made a statement: 'if' starts statements.
      my $c = .call;
      add(@out, $c, $c ~~ Pipeline ?? 'pipest' !! 'callst', $with) unless $c ~~ Call && $c.name eq 'If';
    }
    when ReturnStmt | BreakStmt { add(@out, .value, 'guardexpr', $with) }
    when IfStmt | CaseStmt
    {
      add(@out, .header-decl.init, 'expr', $with) if $_ ~~ IfStmt && .header-decl.defined;
      if $_ ~~ CaseStmt
      {
        add(@out, .subject-decl.init, 'expr', $with) if .subject-decl.defined;
        if .subject-assign.defined
        {
          add(@out, .subject-assign.target, 'lvalue', $with);
          add(@out, .subject-assign.value, 'value', $with);
        }
      }
      add(@out, .cond, 'cond', $with) for .branches;
      roots(.body, $with, @out, $src) for .branches;
      roots(.otherwise, $with, @out, $src);
    }
    when WhileStmt
    {
      add(@out, .header-decl.init, 'expr', $with) if .header-decl.defined;
      add(@out, .cond, 'cond', $with);
      roots(.body, $with, @out, $src);
    }
    when ForStmt
    {
      add(@out, $_, 'expr', $with) for .from, .to, .step;
      roots(.body, $with, @out, $src);
    }
    when ForInStmt
    {
      add(@out, .source, 'expr', $with) unless .source ~~ Interval;
      roots(.body, $with, @out, $src);
    }
    when ForTimesStmt
    {
      add(@out, .count, 'expr', $with);
      roots(.body, $with, @out, $src);
    }
    when Modified
    {
      add(@out, .cond, 'cond', $with);
      # 'exec f() if c': the statement is an expression.
      if .stmt ~~ CallStmt && .src-from >= 0 && $src.substr(.src-from, 5).lc eq 'exec ' | "exec\t"
      {
        add(@out, .stmt.call, 'expr', $with);
      }
      else
      {
        stmt-roots(.stmt, $with, @out, $src);
      }
    }
    when Deferred { stmt-roots(.stmt, $with, @out, $src) }
    when UsingAlias
    {
      add(@out, .order, 'expr', $with);
      roots(.body, $with, @out, $src);
    }
    when WithObject
    {
      add(@out, .subject, 'expr', $with);
      roots(.body, True, @out, $src);
    }
    when TryStmt
    {
      roots($_, $with, @out, $src) for .body, .handler, .finally;
    }
    when SequenceStmt
    {
      roots($_, $with, @out, $src) for .body, .recover;
    }
    when TransactionStmt { roots(.body, $with, @out, $src) }
  }
}

my ($ok, $total) = 0, 0;

# Every expression of the source, by both: how many, and the first that
# differs.
sub same(Str $what, Str $src, Int :$least = 1)
{
  $total++;
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  unless $m
  {
    say "  FAIL  $what";
    note "    the grammar does not read it";
    return;
  }
  my @out;
  roots(.body, False, @out, $src) for |$m.made.functions, |$m.made.methods;
  stmt-roots($_, False, @out, $src) for $m.made.statics;
  my $p = Parser.new(src => $src, trans => user-spans($src, dir => Str, dirs => ())<trans>);
  my $bad = 0;
  for @out -> [$node, $form, $with]
  {
    $p.in-with = $with;
    my ($new, $end) = $p.read($form, $node.src-from);
    my $a = dump($node, {});
    my $b = dump($new, {});
    next if $a eq $b;
    unless $bad++
    {
      my $k = 0;
      $k++ while $k < $a.chars && $a.substr($k, 1) eq $b.substr($k, 1);
      note "    $form at {$node.src-from}: {$src.substr($node.src-from, $node.src-to - $node.src-from).subst(/\n/, ' ', :g)}";
      note "      grammar: ...{$a.substr(max(0, $k - 60), 140)}";
      note "      parser:  ...{$b.substr(max(0, $k - 60), 140)}";
    }
  }
  my $v = !$bad && @out >= $least;
  note "    {@out.elems} expressions, fewer than $least" if @out < $least;
  note "    $bad of {@out.elems} differ" if $bad;
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what, " ({@out.elems})");
}

# ---- made for the purpose ----------------------------------------------------
say 'forms';
same 'operators, their levels and their spans', q:to/END/, least => 12;
User Function Ops()
  Local a := 1, b := 2, c := 3, d, e, f
  d := a + b * c - a / b % c ** 2 ^ 3
  e := !a == b .and. .not. c .or. a <> b .and. a != c
  f := a ?: b ?: c
  e := a $ "abc" .and. "x" # b .and. a >= b .and. a <= c .and. a < b .and. a > c
  e := a in {1, 2} .and. b has "k"
  d := -a + +b - ++a - b--
  d := a %% 2
  If a == b .and. c
    d := 1
  EndIf
Return d
END

same 'calls, members, indexes, aliases, macros', q:to/END/, least => 10;
User Function Calls(oObj, aList)
  Local x
  x := oObj:Method(1, , 3):nField
  x := aList [Len(aList)] [1]
  x := SA1->A1_COD + SA1->(FieldGet(1)) + (cAlias)->&(cField)
  x := &cVar + &(cExpr) + &cFunc.(1, 2)
  x := oObj?.cName + oObj?.Name()
  x := totvs.framework.Thing():New()
  x := ::nProp + ::Method()
  aList [Len(aList)] := 2
  oObj:Run(@x, @aList[1])
  f(x)
  x := { "a" : 1, "b" : { "c" : 2 }, "d" : {1, 2} }
  x := { "a" => 1, "b" => 2 }
  x := { |a, b| a + b, b }
  x := [n] n * 2
  x := { , 1, }
Return x
END

same 'strings, interpolation, literals', q:to/END/, least => 5;
User Function Strs(cName)
  Local x := "Hello, ${cName}! ${ Upper('x') }"
  Local y := 'its' + "a" + 1'000.5 + .5 + .T. + .f. + nil
  Local z := %exp:cName%
  Local w := "unclosed
Return x + y
END

same 'chains, ranges, guards, defer, with object', q:to/END/, least => 8;
User Function Chains(aList, oModel)
  Local n := aList |> Len()
  Local r := 1 .. 10 |> Sum()
  Local g := f() fallback 0
  aList |> Filter([x] x > 1) |> Print()
  defer Close()
  For Local i := 1 To Len(aList) Step 2
    n += i
  Next
  For x In aList
    n += x
  Next
  If n in 1 .. 5
    n := 0
  EndIf
  With Object oModel:GetModel("M")
    :SetValue("A", n)
    n := :GetValue("A")
  End With
  n := a := b := 0
  exec Run() if n > 0
Return n
END

same 'continued lines and comments', q:to/END/, least => 3;
User Function Lines(a)
  Local x := a + ; // more
             2 + /* in */ 3 && done
  Local y := { 1, ;
               2 }
  Default a := 1, b := 2
Return x
END

# ---- xtpl's corpus, its examples, xc's self-test -----------------------------
say 'sources';
my @files = |dir('xtpl/tests').grep(*.extension eq 'xtpl').sort,
            |dir('xtpl/examples').grep(*.d).sort.map({ |dir($_).grep(*.extension eq 'xtpl').sort }),
            'protheus/xc_selftest.xtpl'.IO;
for @files -> $f
{
  next if $f.basename eq '51_legacy.xtpl';
  my $src = $f.slurp(:bin).decode('windows-1252');
  same ~$f, $src, least => 0;
}

say "\n$ok of $total";
exit($ok == $total ?? 0 !! 1);
