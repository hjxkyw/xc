use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# TL++ classes -- native, not an xtpl extension. The 'Class ... EndClass' block
# with 'Data' and the 'Method' signatures, and the implementations
# 'Method name(...) Class Name' loose in the file. Plus the '::' access to the
# object itself. Both directions: the shape that comes out, and what has to be
# refused.

sub program(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  $m ?? $m.made !! Nil
}

sub parses(Str $src) { XC::Grammar.parse($src).defined }

sub expr(Str $src)
{
  my $m = XC::Grammar.parse($src, rule => 'expr', actions => XC::Actions.new(source => $src));
  $m ?? $m.made !! Nil
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# ---- the reference file (xtpl's 48_real_shapes) ---------------------------------
my $ref = q:to/END/;
class MinhaTool
  public method process(jPayLoad as json) as json
endclass

method process(jPayLoad as json) as json class MinhaTool
  local jResp as json
  jResp := JsonObject():New()
  if SC9->(MsSeek(xFilial("SC9") + jPayLoad["numero"]))
    jResp["cliente"] := alltrim(SA1->A1_NOME)
  endif
return jResp
END

check '48: one class and one implementation, no functions',
{
  my $p = program($ref);
  $p.classes == 1 && $p.methods == 1 && $p.functions == 0
};
check '48: the signature in the block -- visibility, typed param, return type',
{
  my $s = program($ref).classes[0].methods[0];
  $s.name eq 'process' && $s.visibility eq 'public'
    && $s.params.map({ .name ~ ':' ~ .declared }).join eq 'jPayLoad:JSON'
    && $s.returns eq 'json'
};
check '48: the implementation -- class, return type, and the body',
{
  my $m = program($ref).methods[0];
  $m.class-name eq 'MinhaTool' && $m.name eq 'process' && $m.returns eq 'json'
    && $m.body.grep(* ~~ ReturnStmt) == 1
};

# ---- the Class ... EndClass block ---------------------------------------------------
my $block = q:to/END/;
Class Fila From Base
  Public Data aBuf as array
  Public Data nHead, nTail
  Data nUsed
  Public Method New(nSize) Constructor
  Public Method Push(xItem)
  Method Grow()
EndClass
END

check 'From, and the data members with type and visibility',
{
  my $c = program($block).classes[0];
  $c.name eq 'Fila' && $c.supers.join eq 'Base'
    && $c.members.map(*.name).join(' ') eq 'aBuf nHead nTail nUsed'
    && $c.members[0].type eq 'array' && $c.members[0].visibility eq 'public'
    && !$c.members[3].visibility.defined
};
check 'the signatures: constructor flagged, and one with no visibility',
{
  my @m = program($block).classes[0].methods;
  @m == 3 && @m[0].constructor && @m[0].visibility eq 'public'
    && !@m[2].constructor && !@m[2].visibility.defined
};
check 'From with more than one base',
{
  program("Class C From A, B\n  Data x\nEndClass").classes[0].supers.join(',') eq 'A,B'
};
check 'a class with no From and no members',
{
  my $c = program("Class Vazia\nEndClass").classes[0];
  $c.name eq 'Vazia' && !$c.supers && !$c.members && !$c.methods
};

# ---- '::' -- access to the object itself --------------------------------------------
check '::aBuf is a Member whose base is the object itself',
{
  my $e = expr('::aBuf');
  $e ~~ Member && $e.base ~~ SelfRef && $e.name eq 'aBuf'
};
check '::Grow() is a method of the object itself',
{
  my $e = expr('::Grow()');
  $e ~~ MethodCall && $e.base ~~ SelfRef && $e.name eq 'Grow' && !$e.args
};
check '::aBuf[::nTail]: an index on a member, and :: reads no variable',
{
  my $e = expr('::aBuf[::nTail]');
  my @n;
  walk-expr($e, { @n.push(.name) if $_ ~~ Name });
  $e ~~ Index && $e.base ~~ Member && @n == 0
};
check '::nHead := 1: :: works as an assignment target',
{
  my $src = "method f() class C\n  ::nHead := 1\nreturn";
  my $m = program($src).methods[0];
  my $a = $m.body[0];
  $a ~~ Assignment && $a.target ~~ Member && $a.target.base ~~ SelfRef
};
check '::aBuf[::nTail] := x: a target with member and index',
{
  my $src = "method f() class C\n  ::aBuf[::nTail] := x\nreturn";
  my $a = program($src).methods[0].body[0];
  $a ~~ Assignment && $a.target ~~ Index && $a.target.base ~~ Member
};
check 'Self is still an ordinary name, and ::x uses the object without a variable read',
{
  expr('Self') ~~ Name && !expr('::x').base.isa(Name)
};

# ---- what has to be refused -----------------------------------------------------------
my @refuse =
  "class C\n  data x"                          => 'class without endclass',
  "method f(x) class"                          => 'implementation without the class name',
  "Class C\n  Data\nEndClass"                  => 'data with no name',
  "Class C\n  Method\nEndClass"                => 'method with no name',
  "::"                                         => 'colons with no member',
  ;

for @refuse -> $c
{
  check "refuses: {$c.value}", { !parses($c.key) };
}

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
