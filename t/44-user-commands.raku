use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;
use XC::Check;
use XC::Commands;

# The commands and translations a source brings with it -- '#xcommand',
# '#xtranslate', in the file or in a plain-text include file -- known where
# they are used: a command taken whole, one that stands for a function's
# header with its body, a translation as a value. Each source goes through
# as it came, byte for byte, and passes the checks. The forms are those of
# real libraries: nginformatica's testsuite.ch and json.ch.

sub parse(Str $src)
{
  my $*FURTHEST = 0;
  XC::Grammar.parse($src, actions => XC::Actions.new(source => $src))
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# As it came, and no error from the checks.
sub same(Str $what, Str $src)
{
  check $what, {
    my $m = parse($src);
    $m && emit($m.made, $src) eq $src && !check-all($m.made, source => $src)<errors>
  };
}
sub warnings(Str $src) { check-all(parse($src).made, source => $src)<warnings>.map(*.value).List }

my $suite = q:to/END/;
  #include "totvs.ch"
  #include "tlpp-core.th"

  #xcommand TestSuite <cName> ;
      [ <description: Description> <cDesc> ] ;
      [ <verbose: Verbose> ] ;
      => ;
      Static __NAME__ := <(cName)> ;;
      _ObjNewClass( TestSuite_<cName>, LongNameClass )
  #xcommand EndTestSuite => _ObjEndClass()
  #xcommand Feature <cFeat> [ <description: Description> <cDesc> ] => _ObjClassMethod( Feat_<cFeat>, , )
  #xcommand Feature <cFeat> TestSuite <cSuite> => Function ___TestSuite_<cSuite>____Feat_<cFeat>()
  #xcommand CompileTestSuite <cSuite> => Function U_<cSuite> ;; Return 0

  TestSuite Calc Verbose Description 'Contas'
      Feature Soma Description 'soma dois numeros'
  EndTestSuite

  Feature Soma TestSuite Calc
      Local nA := 1
      ::Expect( nA + 1 ):ToBe( 2 )
      Return

  CompileTestSuite Calc
  END

same "a library's commands: the suite whole, a feature a function with its body", $suite;
check "the feature's body is read: its local is known, and read",
{
  !warnings($suite).first(*.contains('nA'))
};

my $json = q:to/END/;
  #include "totvs.ch"
  #include "tlpp-core.th"

  #xtranslate @Not_Eof => ( Self:nPosition <= Self:nSourceSize )
  #xtranslate @Current => Self:aChars\[ Self:nPosition \]
  #xtranslate @Error Line <line> Column <column> => Return JSONError():New( Self:cError, <line>, <column> )
  #xtranslate @Next => Self:nPosition++; Self:nColumn++
  #xtranslate \[ \# <cKey> \] => :Get( <cKey> )
  #xtranslate \[ \# <cKey> \] := <xValue> => :Set( <cKey>, <xValue> )

  Method Lex() Class JSONLexer
      Local cChar := ''
      Local oOut := JsonObject():New()
      While @Not_Eof .And. ( IsAlpha( @Current ) .Or. IsDigit( @Current ) )
          cChar += @Current
          @Next
      EndDo
      If Empty( cChar )
          @Error Line ::nLine Column ::nColumn
      EndIf
      oOut[#'chars'] := cChar
  Return oOut[#'chars']
  END

same "a library's translations: as a value, as a statement, after a value, assigned", $json;
check "the variables in a translation are read: no 'never read'",
{
  !warnings($json).first(*.contains('never read'))
};

same "optional clauses in any order, and a '#command' word cut to four letters",
  qq[#include "totvs.ch"\n#include "tlpp-core.th"\n#command REPORTE <x> [TITULO <t>] [LARGURA <n>] => u_Rep(<x>, <t>, <n>)\n\n]
  ~ qq[User Function f(a)\n  REPORTE a LARGURA 80 TITULO "x"\n  REPO a TITU "y"\nReturn nil\n];

same "two values side by side are two: 'Enable Environment 'T3' 'S SC 01''; a class's data among the commands",
  qq[#include "totvs.ch"\n#include "tlpp-core.th"\n]
  ~ qq[#xcommand TestSuite <cName> => _ObjNewClass( TestSuite_<cName>, LongNameClass )\n]
  ~ qq[#xcommand Enable Environment <cCompany> <cBranch> => _ObjClassData( cCompany, String, , <cCompany> )\n]
  ~ qq[#xcommand EndTestSuite => _ObjEndClass()\n\n]
  ~ qq[TestSuite Custo\n    Enable Environment 'T3' 'S SC 01'\n    Data nRegistros As Numeric\nEndTestSuite\n];
same "a translation inside another's part, and one after 'Return'",
  qq[#include "totvs.ch"\n#include "tlpp-core.th"\n]
  ~ qq[#xtranslate If <expr> ? <true> : <false> => If(<expr>, <true>, <false>)\n]
  ~ qq[#xtranslate Eval <blockName>([<prm,...>]) => Eval(<blockName> [, <prm>])\n\n]
  ~ qq[User Function f(bIt, xV)\n  Local xC := If bIt == Nil ? xV : Eval bIt( xV )\n  Return If xC == Nil ;\n    ? 0 ;\n    : xC\n];

check "without a directive, a line of the same words is not a command",
{
  !parse(qq[#include "totvs.ch"\n\nUser Function f(a)\n  REPORTE a\nReturn nil\n])
};

check "a pattern matches the whole statement, or it is not the command",
{
  !parse(qq[#include "totvs.ch"\n#xcommand REPORTE <x> TITULO <t> => u_Rep(<x>, <t>)\n\nUser Function f(a)\n  REPORTE a\nReturn nil\n])
};

# ---- include files ---------------------------------------------------------------
my $dir = $*TMPDIR.add("xc-usercmd-$*PID");
mkdir $dir.add('inc');
spurt $dir.add('inc/mine.ch'), "#xcommand SAUDA <x> => ConOut(<x>)\n";
spurt $dir.add('beside.ch'), "#include \"other.ch\"\n";
spurt $dir.add('inc/other.ch'), "#xtranslate @Agora => Time()\n";
spurt $dir.add('zipped.ch'), "#zip\x[01]\x[02]compressed";

check "an include file found beside the source, then in the include folders, and the ones it includes",
{
  my $src = qq[#include "totvs.ch"\n#include "mine.ch"\n#include "beside.ch"\n#include "zipped.ch"\n\n]
          ~ qq[User Function f()\n  SAUDA "oi"\nReturn @Agora\n];
  my %u = user-spans($src, dir => $dir.Str, dirs => [$dir.add('inc').Str]);
  %u<cmd>.elems == 1 && %u<trans>.elems == 1
};

check "bin/xc --includes: the folders, ';' between them",
{
  spurt $dir.add('f.xtpl'), qq[#include "totvs.ch"\n#include "mine.ch"\n\nUser Function f()\n  SAUDA "oi"\nReturn nil\n];
  my $none = run($*EXECUTABLE, 'bin/xc', '--check', $dir.add('f.xtpl').Str, :out, :err);
  $none.out.slurp(:close); $none.err.slurp(:close);
  my $p = run($*EXECUTABLE, 'bin/xc', '--check', "--includes=/nowhere;{$dir.add('inc')}", $dir.add('f.xtpl').Str, :out, :err);
  my $out = $p.out.slurp(:close);
  $p.err.slurp(:close);
  $none.exitcode == 1 && $p.exitcode == 0 && $out.contains('f.xtpl: ok')
};

for $dir.add('inc').dir { .unlink }
$dir.add('inc').rmdir;
for $dir.dir { .unlink }
$dir.rmdir;

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
