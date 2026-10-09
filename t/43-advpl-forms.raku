use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;
use XC::Check;

# Forms of real AdvPL and TL++ -- found running xc over 1,407 sources from
# GitHub -- that xc did not read. TL++ goes through xc as it came: each source
# here compiles to itself, byte for byte, and passes the checks.

sub parse(Str $src)
{
  my $*FURTHEST = 0;
  XC::Grammar.parse($src, actions => XC::Actions.new(source => $src))
}

my $head = qq[#include "totvs.ch"\n#include "tlpp-core.th"\n\n];

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# As it came, and no error from the checks.
sub same(Str $what, Str $body)
{
  check $what, {
    my $src = $head ~ $body;
    my $m = parse($src);
    $m && emit($m.made, $src) eq $src && !check-all($m.made, source => $src)<errors>
  };
}
# The warnings the checks give, as text.
sub warnings(Str $body)
{
  my $src = $head ~ $body;
  check-all(parse($src).made, source => $src)<warnings>.map(*.value).List
}

# ---- functions --------------------------------------------------------------
same 'a function with no parentheses', "User Function TLeroy\nreturn 1\n";
same 'a return type; integer, decimal, codeblock among the types',
  "Static Function Scheddef() as array\nreturn \{\}\n\nUser Function f(n as integer, x as decimal, b as codeblock) as logical\nreturn .T.\n";

# ---- assignments as values --------------------------------------------------
same 'an assignment in parentheses is a value',
  "User Function f(a)\n  Local lErr := .F.\n  if !( lErr := g(\@a) )\n    a := 1\n  endif\nreturn lErr\n";
same "chained, from the right -- and 'b = 0' in a value compares",
  "User Function f(a)\n  Local b := 0, c := 0\n  a := b := c := 0\n  a := b = 0\nreturn a + c\n";

# ---- statements ---------------------------------------------------------------
same "'Do While' ... 'EndDo'", "User Function f(a)\n  Do While a > 0\n    a--\n  EndDo\nreturn a\n";
same "'Default', one or more", "User Function f(a, b)\n  Default a := 1\n  DEFAULT b := \{\}, a := 2\nreturn a\n";
same "';' between statements on one line; at its end, a continuation",
  "User Function f(a)\n  conout(1); a++; a += 2\n  a := 1 + ;\n    2\nreturn a\n";
same "'try' ... 'catch' ... 'endtry'; without 'catch' too",
  "User Function f(a)\n  Local oErr\n  try\n    a := 1\n  catch oErr\n    conout(oErr:Description)\n  endtry\n  try\n    a := 2\n  endtry\nreturn a\n";
same "'Break' in a 'begin sequence'", "User Function f(a)\n  begin sequence\n    Break(a)\n  recover\n    a := 0\n  end sequence\nreturn a\n";
same "'Begin Transaction' ... 'End Transaction'", "User Function f(a)\n  Begin Transaction\n    a := 1\n  End Transaction\nreturn a\n";

# ---- the file ---------------------------------------------------------------------
same "a 'Static' of the file, typed or not, with a value or not",
  "Static aDados__ as array\nStatic cToken__ := \"\" as character // a comment\nStatic lInit := .F.\n\nUser Function f()\n  aDados__ := \{\}\n  lInit := .T.\nreturn cToken__\n";

# ---- classes ------------------------------------------------------------------------
same "'Data ... default', 'Static Method', visibilities, '::' calls as statements",
  "Class Gw from Base\n  Public Data cId as character default \"\"\n  Static Method Make()\n  Private Method Wait( nWait as integer )\n  Public Static Method Other()\n  Method New() Constructor\nEndClass\n\nMethod New() Class Gw\n  ::Init()\n  ::oLog:Error( \"x\", \{ 1 \} )\n  ::cId := \"a\"\nReturn Self\n";

# ---- more forms -----------------------------------------------------------------
same "a field macro: 'SX3->\&(\"X3_CAMPO\")', '(cAlias)->\&(cField)', read and written",
  "User Function f(cAlias, cField)\n  Local aF := \{\}\n  aAdd(aF, allTrim(SX3->\&(\"X3_CAMPO\")))\n  (cAlias)->\&(cField) := 1\n  if( allTrim((cAlias)->\&(cField)) \$ \"ab\" )\n    aF := \{\}\n  endif\nreturn aF\n";
same "'end case', and 'End' closing an 'if'",
  "User Function f(a)\n  do case\n  case a > 1\n    a := 1\n  end case\n  if a > 2\n    a := 2\n  End\nreturn a\n";
same "'finally' in a 'try'", "User Function f(a)\n  Local oE\n  try\n    a := 1\n  catch oE\n    a := 2\n  finally\n    a := 3\n  endtry\nreturn a\n";
same "'Return()'; '\&cFunc.()' called, as a value and as a statement",
  "User Function f(a, cF)\n  if a > 1\n    Return()\n  endif\n  a := \&cF.()\n  \&cF.(\"x\")\nreturn a\n";
same "chained in a declaration: 'Private a := b := c := 0'",
  "User Function f()\n  Local nB := 0, nC := 0\n  Private nA := nB := nC := 0\nreturn nA + nB + nC\n";
same "'Default' after the locals", "User Function f(a)\n  Local x as variant\n  Default a := 1\n  x := a\nreturn x\n";
same "'If( c, a, b )' as a statement; 'if( c )' with a body is still a block",
  "User Function f(a)\n  a := g() ; If( Empty(a), a := \"x\", Nil )\n  if( a > 1 )\n    a := 0\n  endif\nreturn a\n";
same "an annotation on a method in its class", "Class C\n  \@Post(\"/c/x\")\n  Public Method PostX() as logical\nEndClass\n\nMethod PostX() Class C\nReturn .T.\n";

# ---- the survey's tail ------------------------------------------------------------
same "'( fA(), fB() )': a list in parentheses, each in turn -- in a code block too",
  "User Function f(a, b)\n  Local aB := \{\}\n  aAdd( aB, \{ 1, .T., \{ || Iif( b ,( g( a ) , h() ),) \} \} )\n  a := ( g(), h(), 3 )\nreturn aB\n";
same "an empty element in an array, over continued lines with comments",
  "User Function f(b)\n  Local aP := \{ \"P\",;\t\t//the kind\n    b,;\t\t//the question\n    ,;\t\t//no alias\n    1 \}\nreturn aP\n";
same "'For i = 1 To', 'Next (i)'", "User Function f()\n  Local i, n := 0\n  For i = 1 To 3\n    n++\n  Next (i)\nreturn n\n";
same "'aTail(a) := ...': the last element", "User Function f(a)\n  aTail(a) := \{ 1, 2 \}\nreturn a\n";
same "a namespaced call, 'oObj::Method()', '\&( ... )' and '( ... )' as statements",
  "User Function f(o, b)\n  Local n\n  MvcLogin.Cad():Make()\n  n := o::connect()\n  \&( 'o:F' + b + '()' )\n  ( if( !Empty(b), n := b, Nil ) ) // a comment\nreturn n\n";
same "'SA2->( a, b, c )' as a statement", "User Function f()\n  SA2->( dbSelectArea(\"SA2\"), dbSetOrder(3), dbGoTop() )\nreturn nil\n";
same "'End Class'; a method without parentheses", "Class C\n  Public Method GetEnum as variant\nEnd Class\n";
same "the mail commands", "User Function f(cS, cA, cP)\n  Local lOk\n  CONNECT SMTP SERVER cS ACCOUNT cA PASSWORD cP RESULT lOk\n  SEND MAIL FROM cA TO cA SUBJECT \"x\" BODY \"y\" RESULT lOk\n  DISCONNECT SMTP SERVER\nreturn lOk\n";

# ---- statics, as Protheus takes them (tried on an AppServer, 8 October 2026) ---------
same "file statics between functions; a static after a statement in a function, which other functions see",
  "static cFirst := \"cFirst\"\n\nfunction u_stat_test_1(cParm)\n  default cParm := \"a\"\n  static cInside := \"cInside\"\n  default cParm := \"b\"\n  conout(\"u_stat_test_1 \" + cFirst + \" \" + cInside + \" \" + cParm)\n  return\n\nstatic cSecond := \"cSecond\"\n\nfunction u_stat_test_2()\n  conout(\"u_stat_test_2 \" + cSecond + \" \" + cInside)\n  return\n\nstatic cThird := \"cThird\"\n\nfunction u_stat_test_3()\n  u_stat_test_1()\n  u_stat_test_2()\n  conout(\"u_stat_test_3 \" + cThird)\n  return\n";
same "a static at the top of a function, read by another; one after calls",
  "function u_t1(cParm)\n  static cTopInside := \"cTopInside\"\n  default cParm := \"a\"\n  conout(cParm)\n  return\n\nfunction u_t2()\n  conout(cTopInside)\n  u_t1()\n  static cAnother := \"cAnother\"\n  conout(cAnother)\n  return\n";
check "and the checks have nothing to say about it",
{
  !warnings("static cFirst := \"a\"\n\nfunction u_t1(cParm)\n  default cParm := \"a\"\n  static cInside := \"b\"\n  conout(cFirst + cInside + cParm)\n  return\n\nstatic cSecond := \"c\"\n\nfunction u_t2()\n  conout(cSecond + cInside)\n  return\n")
};

# ---- the commands of TOTVS' include files: taken whole, as written ------------
same 'one line, and continued with ;',
  "User Function f()\n  Local oDlg, cQry := \"select 1\"\n  DEFINE MSDIALOG oDlg TITLE \"x\" ;\n    FROM 0,0 TO 10,10 PIXEL\n  ACTIVATE MSDIALOG oDlg CENTERED\n  TCQUERY cQry NEW ALIAS \"QRY\"\n  ADD OPTION aRotina TITLE 'Ver' ACTION 'VIEWDEF.X' OPERATION 1 ACCESS 0\n  PREPARE ENVIRONMENT EMPRESA \"T1\" FILIAL \"01\"\n  Set Filter To\nreturn nil\n";
same "'Count to', and the RF terminal's: 'VTRead', 'VTPause', 'VTClear Screen'",
  "User Function f()\n  Local nCount := 0\n  Count to nCount For SA1->A1_EST == \"SP\"\n  VTClear Screen\n  VTRead\n  VTPause\nreturn nCount\n";
same "'@ row, col SAY ...'; an annotation is '@' and its name together",
  "\@Get(\"/hello\")\nUser Function f()\n  Local oDlg\n  \@ 1, 0 VTSAY \"x\"\n  \@ 10, 20 SAY \"y\" OF oDlg PIXEL\nreturn nil\n";
same "'BeginSql' ... 'EndSql', 'BeginContent' ... 'EndContent': whole",
  "User Function f()\n  BeginSql alias \"QRY\"\n    SELECT * FROM %table:SA1% SA1 WHERE %notDel%\n  EndSql\n  BeginContent var cCss as CSS\n    .a \{ color: red; \}\n  EndContent\nreturn nil\n";
same "a directive inside a function; a command at the file's level",
  "PUBLISH USER MODEL REST NAME Cad SOURCE \"Mvc.Cad\"\n\nUser Function f()\n#IFDEF TOP\n  conout(\"top\")\n#ENDIF\nreturn nil\n";
same "not a command: 'Set(1)' a call, 'set := 1' an assignment",
  "User Function f()\n  Local set := 0\n  Set(1)\n  set := 1\nreturn set\n";
check "a word not on the list is not taken for a command: a typo stays an error",
{
  !parse($head ~ "User Function f()\n  DEFINEX MSDIALOG oDlg TITLE \"x\"\nreturn nil\n")
};

# ---- what the checks make of them ------------------------------------------------
check "'Default' reads what it sets: no 'never read'",
{
  !warnings("User Function f(a)\n  Local n\n  Default n := 1\nreturn a\n").first(*.contains('never read'))
};
check "the variables of a command are read: no 'never read'",
{
  !warnings("User Function f()\n  Local oDlg\n  DEFINE MSDIALOG oDlg TITLE \"x\" FROM 0,0 TO 9,9 PIXEL\nreturn nil\n")
};
check "the name in a field macro is read",
{
  !warnings("User Function f(cAlias)\n  Local cF := \"A1_COD\"\n  conout((cAlias)->\&(cF))\nreturn nil\n")
};
check "every statement closes the prologue -- a 'Default' too: no local after it",
{
  !parse($head ~ "User Function f(a)\n  Default a := 1\n  Local x := 1\nreturn x\n")
    && !parse($head ~ "User Function f()\n  defaultValue := 1\n  Local x := 1\nreturn x\n")
};
check "the names in a list in parentheses are read; 'aTail(a) := x' reads 'a'",
{
  !warnings("User Function f()\n  Local nA := 1, aL := \{ 1 \}\n  conout( ( nA, 2 ) )\n  aTail(aL) := 3\nreturn nil\n")
};
check "a file 'Static' is known in every function of the file",
{
  !warnings("Static nCount := 0\n\nUser Function f()\n  nCount++\nreturn nCount\n")
};

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
