use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Emit;
use XC::Check;

# A large source is parsed in parts (XC::Grammar, in-parts): each a run of
# whole top-level items, parsed as a text of its own, the trees put together.
# What comes out has to be what comes out of the source read whole, to the
# byte, and what the checks say too. Here every source is read both ways, with
# a part at every place one may start ($*XC-PART = 1): xtpl's corpus and its
# examples, xc's self-test, and sources made to put a part where none may go.

sub run(Str $src, Int $part --> Hash)
{
  my $*XC-PART = $part;
  my $*FURTHEST = 0;
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  return %( kind => 'none', furthest => $*FURTHEST ) unless $m;
  my %c = check-all($m.made, lines => $src.lines.elems, source => $src);
  my $out = %c<errors> ?? '' !! (try emit($m.made, $src)) // "died: {$!.message}";
  %( kind => $m.^name, parts => ($m.?parts // ()).elems, out => $out,
     said => (|%c<errors>, |%c<warnings>).map({ "{.key}: {.value}" }).sort.join("\n") )
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  note "    {$!.message}" if $!;
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

# The same out of the whole and out of the parts -- and parts there were.
sub same(Str $what, Str $src, Int :$parts)
{
  check $what, {
    my %w = run($src, 1_000_000);
    my %p = run($src, 1);
    note "    whole: {%w<kind>}, parts: {%p<kind>} ({%p<parts>})" unless %p<kind> eq 'XC::Grammar::Parts';
    note "    the output differs" unless %w<out> eq %p<out>;
    note "    what is said differs:\n      {%w<said>}\n    --\n      {%p<said>}" unless %w<said> eq %p<said>;
    %p<kind> eq 'XC::Grammar::Parts' && %w<out> eq %p<out> && %w<said> eq %p<said>
      && (!$parts.defined || %p<parts> == $parts)
  };
}

# The parts' first lines, the part at every place one may start.
sub firsts(Str $src --> List)
{
  my $*XC-PART = 1;
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  return ('no parse',) unless $m;
  return ('read whole',) unless $m.^name eq 'XC::Grammar::Parts';
  $m.parts.map({ .Str.lines.first(*.trim).trim }).List
}

# ---- where a part may start, and where not -----------------------------------
my $where = q:to/END/;
#include "totvs.ch"

/* User Function Commented()
   Return nil */
User Function Primeira()
  Local cQ := ""
  BeginSql Alias "T"
    SELECT 1
    Function inside SQL
  EndSql
  cQ := "x" + ;
        "y"
Return cQ

Static Function Segunda()
Return nil

// annotations after a function are statements of its body: no part here
@Get("/a")
@Version(1)
Static Function Terceira()
Return nil

Class Pessoa From Base
  Data cNome
  Method New() Constructor
  Method Nome()
EndClass

Method New() Class Pessoa
  ::cNome := ""
Return self

Method Nome() Class Pessoa
Return ::cNome
END

check 'a part at each function, method and class -- not in a comment, SQL or a class body, nor under annotations',
{
  my @f = firsts($where);
  my @want = '#include "totvs.ch"', 'User Function Primeira()', 'Static Function Segunda()',
             'Class Pessoa From Base', 'Method New() Class Pessoa', 'Method Nome() Class Pessoa';
  note "    {@f.raku}" unless @f.join("\n") eq @want.join("\n");
  @f.join("\n") eq @want.join("\n")
};
same 'and what comes out is the same', $where, parts => 6;

# A command of the source's own, defined in one part and used in others; a
# translation too.
same "the source's own commands and translations, used in later parts", q:to/END/, parts => 3;
#xcommand REPORTE <x> => conout(<x>)
#xtranslate @Agora => Time()

User Function A()
  REPORTE "a"
Return @Agora

User Function B()
  REPORTE "b"
Return nil
END

# A source with accents: the copy's stand-ins are taken from the source, in
# every part.
same 'accents, in names and strings, in every part', qq:to/END/, parts => 2;
User Function Ação()
  Local cNação := "São Paulo"
  conout(cNação)
Return cNação

User Function Preço()
  Local nPreço := 1
Return nPreço
END

# A part that does not parse: the source is read whole, and the line it stops
# at is the one it always was.
check 'a part that does not parse: read whole, the same line said',
{
  my $src = "User Function A()\nReturn 1\n\nUser Function B()\n  x := (1 +\nReturn 2\n";
  my %w = run($src, 1_000_000);
  my %p = run($src, 1);
  %w<kind> eq 'none' && %p<kind> eq 'none' && %w<furthest> == %p<furthest> && %w<furthest> > 0
};

# A rule of the grammar, not a whole source: never in parts.
check 'a rule asked for is read as it is',
{
  my $*XC-PART = 1;
  my $src = "User Function A()\nReturn 1\n\nUser Function B()\nReturn 2\n";
  XC::Grammar.parse($src, rule => 'TOP', actions => XC::Actions.new(source => $src)) ~~ Match
};

# ---- the corpus, both ways ---------------------------------------------------
my @files = |dir('xtpl/tests').grep(*.extension eq 'xtpl').sort,
            |dir('xtpl/examples').grep(*.d).sort.map({ |dir($_).grep(*.extension eq 'xtpl').sort }),
            'protheus/xc_selftest.xtpl'.IO;
my $read = 0;
my @differ;
for @files -> $f
{
  next if $f.basename eq '51_legacy.xtpl';
  my $src = $f.slurp(:bin).decode('utf-8');
  my %w = run($src, 1_000_000);
  next if %w<kind> eq 'none';
  my %p = run($src, 1);
  $read++;
  @differ.push($f.basename) unless %w<out> eq %p<out> && %w<said> eq %p<said> && %p<kind> ne 'none';
}
check "the corpus read whole and in parts, the same ($read sources)", { $read >= 70 && !@differ };
note "    differ: {@differ.head(10).join(', ')}" if @differ;

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
