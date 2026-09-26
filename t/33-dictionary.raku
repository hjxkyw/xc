use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::Check;

# The dictionary: an exported SX3, loaded as xtpl loads it, and the fields a
# program uses checked against it -- names, types of literals, sizes of
# strings. xtpl's two tests with a dictionary (07_types, 50_dictionary) are in
# t/31-xtpl-corpus.raku, where xc's warnings equal xtpl's; these are the rest.

my $dir = $*TMPDIR.add("xc-dict-$*PID");
mkdir $dir;
my $n = 0;
sub dict-file(Str $text --> Str)
{
  my $f = $dir.add("d{++$n}.csv");
  spurt $f, $text;
  ~$f
}

my %sx3 = load-dictionary(dict-file(q:to/END/));
  X3_ARQUIVO,X3_CAMPO,X3_TIPO,X3_TAMANHO,X3_TITULO
  SA1,A1_COD,C,6,Codigo
  SA1,A1_NOME,C,40,Nome
  SA1,A1_SALDO,N,14,Saldo
  SA1,A1_BLOQ,L,1,Bloqueado
  SA1,A1_OBS,M,10,Observacao
  END

# The warnings (or, strict, the errors) about the dictionary, as 'line: message'.
sub found(Str $lines, Bool :$strict = False, :%dictionary = %sx3)
{
  my $src = "external alias SA1\nuser function f(cAl)\n  local x := 0\n$lines\nreturn x\n";
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(source => $src));
  my %c = check-all($m.made, :%dictionary, :$strict);
  ($strict ?? %c<errors> !! %c<warnings>).map({ .key ~ ': ' ~ .value }).List
}

my ($ok, $total) = 0, 0;
sub check(Str $what, &test)
{
  $total++;
  my $v = try test();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FAIL  '), $what);
}

sub says(Str $what, Str $lines, *@found) { check $what, { found($lines) eqv @found.List } }

# ---- loading -------------------------------------------------------------------------------
check 'the columns found by their headers, the type by its first letter, the size as a number',
{
  %sx3<SA1><A1_NOME> eqv ['C', 40] && %sx3<SA1><A1_OBS> eqv ['M', 10] && %sx3<SA1>.elems == 5
};
check 'other headers, other order, padded values, a quoted title with a comma',
{
  my %d = load-dictionary(dict-file(qq:to/END/));
    CAMPO,TAMANHO,ALIAS,TIPO,TITULO
    "  B1_DESC  ",40,"SB1 ",Caracter,"Descricao, longa"
    B1_PESO,x,SB1,Numerico,Peso
    END
  %d<SB1><B1_DESC> eqv ['C', 40] && %d<SB1><B1_PESO> eqv ['N', 0]
};
check 'no header it knows: the first two columns are the alias and the field, no types',
{
  my %d = load-dictionary(dict-file("SC5,C5_NUM\nSC5,C5_CLIENTE\n"));
  %d<SC5>.keys.sort.join(' ') eq 'C5_CLIENTE C5_NUM' && %d<SC5><C5_NUM> eqv ['', 0]
};

# ---- names ----------------------------------------------------------------------------------
says 'a known field: nothing', "  x := SA1->A1_NOME";
says 'a field in another case: nothing', "  x := sa1->a1_nome";
says 'an alias the dictionary does not have',
  "  x := SZZ->ZZ_COD",
  "4: nothing in this function opened SZZ. Wrap the use in 'using alias SZZ do', or declare 'external alias SZZ' if the caller opens it.",
  "4: alias 'SZZ' is not in the dictionary. A table that is missing usually means the export is out of date.";
says 'a field it does not have, with the one it may be',
  "  x := SA1->A1_NMOE",
  "4: 'SA1->A1_NMOE' is not a field of SA1. Did you mean A1_NOME?";
says 'a field with nothing like it',
  "  x := SA1->ZZZZ",
  "4: 'SA1->ZZZZ' is not a field of SA1.";
says 'once per line and field',
  "  x := SA1->A1_NMOE + SA1->A1_NMOE",
  "4: 'SA1->A1_NMOE' is not a field of SA1. Did you mean A1_NOME?";
says 'an area held in a variable is not checked',
  "  x := (cAl)->A1_NMOE";
check 'a chain over rows("SA1"): the record\'s fields before the map, not after',
{
  found("  x := rows(\"SA1\") |> filter([r] r:A1_SALDOX > 0) |> map([r] r:A1_COD) |> map([c] c:Len)")
    eqv ("4: 'SA1->A1_SALDOX' is not a field of SA1. Did you mean A1_SALDO?",)
};
says 'a chain over rows() of a variable is not checked',
  "  x := rows(cAl) |> map([r] r:A1_NMOE)";

# ---- types and sizes ------------------------------------------------------------------------
says 'a literal of the wrong type, assigned',
  "  SA1->A1_NOME := 5",
  "4: SA1->A1_NOME is character, assigned a numeric value.";
says 'compared, either way round, and a negative number is a number',
  "  x := 1 if SA1->A1_NOME == -5\n  x := 2 if .T. == SA1->A1_SALDO",
  "4: SA1->A1_NOME is character, compared with a numeric value.",
  "5: SA1->A1_SALDO is numeric, compared with a logical value.";
says 'a memo takes characters', "  SA1->A1_OBS := \"texto\"";
says 'Nil, a variable, a call: not literals, not checked',
  "  SA1->A1_NOME := Nil\n  SA1->A1_NOME := x\n  SA1->A1_NOME := str(x)";
says 'a string that fits, exactly: nothing', "  SA1->A1_COD := \"123456\"";
says 'a string too long, assigned: AdvPL cuts it',
  "  SA1->A1_COD := \"1234567\"",
  "4: SA1->A1_COD holds 6 characters, but is assigned 7.";
says 'compared, a long string is only a comparison', "  x := 1 if SA1->A1_COD == \"1234567\"";
says "'=' as a statement counts as a comparison, as in xtpl",
  "  SA1->A1_SALDO = \"x\"",
  "4: SA1->A1_SALDO is numeric, compared with a character value.";

# ---- strict, and without a dictionary --------------------------------------------------------
check '--dict-strict: the same findings are errors',
{
  found("  SA1->A1_COD := \"1234567\"", :strict) eqv ("4: SA1->A1_COD holds 6 characters, but is assigned 7.",)
};
check 'no dictionary: nothing to check against',
{
  found("  x := SA1->A1_NMOE\n  SA1->A1_COD := 5", dictionary => %()) eqv ()
};

# ---- the driver ------------------------------------------------------------------------------
sub xc(*@args)
{
  my $p = run $*EXECUTABLE, 'bin/xc', |@args, :out, :err;
  my $out = $p.out.slurp(:close);
  ($p.exitcode, $p.err.slurp(:close))
}
my $src = $dir.add('f.xtpl');
spurt $src, "external alias SA1\nuser function f()\n  SA1->A1_COD := \"1234567\"\nreturn 1\n";
my $csv = dict-file("X3_ARQUIVO,X3_CAMPO,X3_TIPO,X3_TAMANHO\nSA1,A1_COD,C,6\n");

check 'bin/xc --dict: a warning, and the .tlpp written',
{
  my ($code, $err) = xc('--dict', $csv, ~$src);
  $code == 0 && $err.contains("f.xtpl:3: warning: SA1->A1_COD holds 6 characters, but is assigned 7.")
    && $dir.add('f.tlpp').e
};
check 'bin/xc --dict --dict-strict: an error, and no .tlpp',
{
  $dir.add('f.tlpp').unlink;
  my ($code, $err) = xc('--dict', $csv, '--dict-strict', ~$src);
  $code == 1 && $err.contains("f.xtpl:3: SA1->A1_COD holds 6 characters") && !$dir.add('f.tlpp').e
};
check 'bin/xc: --dict-strict alone, a --dict file that is not there, an option that does not exist',
{
  xc('--dict-strict', ~$src)[1].contains('--dict-strict needs --dict')
    && xc('--dict', "$dir/nowhere.csv", ~$src)[1].contains('nowhere.csv: no such file')
    && xc('--dcit', ~$src)[1].contains('--dcit: no such option')
};

.unlink for $dir.dir;
rmdir $dir;

say "\n  $ok of $total";
exit($ok == $total ?? 0 !! 1);
