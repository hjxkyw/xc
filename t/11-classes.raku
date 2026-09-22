use lib 'lib';
use XC::Grammar;
use XC::Actions;
use XC::AST;

# Classes do TLPP -- nativas, nao extensao do xtpl. O bloco 'Class ... EndClass'
# com 'Data' e as assinaturas 'Method', e as implementacoes 'Method nome(...)
# Class Nome' soltas no arquivo. Mais o '::' de acesso ao proprio objeto. As
# duas direcoes: a forma que sai, e o que tem de ser recusado.

sub prog(Str $src)
{
  my $m = XC::Grammar.parse($src, actions => XC::Actions.new(fonte => $src));
  $m ?? $m.made !! Nil
}

sub casa(Str $src) { XC::Grammar.parse($src).defined }

sub expr(Str $src)
{
  my $m = XC::Grammar.parse($src, rule => 'expr', actions => XC::Actions.new(fonte => $src));
  $m ?? $m.made !! Nil
}

my ($ok, $total) = 0, 0;
sub confere(Str $o-que, &teste)
{
  $total++;
  my $v = try teste();
  $ok++ if $v;
  say(($v ?? '  ok    ' !! '  FALHA '), $o-que);
}

# ---- o arquivo de referencia (48_real_shapes) ------------------------------------
my $ref = q:to/FIM/;
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
FIM

confere '48: uma classe e uma implementacao, nenhuma funcao',
{
  my $p = prog($ref);
  $p.classes == 1 && $p.metodos == 1 && $p.funcoes == 0
};
confere '48: a assinatura no bloco -- visibilidade, param tipado, retorno',
{
  my $a = prog($ref).classes[0].metodos[0];
  $a.nome eq 'process' && $a.visib eq 'public'
    && $a.params.map({ .nome ~ ':' ~ .declarado }).join eq 'jPayLoad:JSON'
    && $a.retorno eq 'json'
};
confere '48: a implementacao -- classe, retorno, e o corpo com os comandos',
{
  my $m = prog($ref).metodos[0];
  $m.classe eq 'MinhaTool' && $m.nome eq 'process' && $m.retorno eq 'json'
    && $m.corpo.grep(* ~~ Retorno) == 1
};

# ---- o bloco Class ... EndClass --------------------------------------------------
my $bloco = q:to/FIM/;
Class Fila From Base
  Public Data aBuf as array
  Public Data nHead, nTail
  Data nUsed
  Public Method New(nSize) Constructor
  Public Method Push(xItem)
  Method Grow()
EndClass
FIM

confere 'From, e os atributos com tipo e visibilidade',
{
  my $c = prog($bloco).classes[0];
  $c.nome eq 'Fila' && $c.supers.join eq 'Base'
    && $c.atributos.map(*.nome).join(' ') eq 'aBuf nHead nTail nUsed'
    && $c.atributos[0].tipo eq 'array' && $c.atributos[0].visib eq 'public'
    && !$c.atributos[3].visib.defined
};
confere 'as assinaturas: construtor marcado, e uma privada sem visibilidade',
{
  my @m = prog($bloco).classes[0].metodos;
  @m == 3 && @m[0].construtor && @m[0].visib eq 'public'
    && !@m[2].construtor && !@m[2].visib.defined
};
confere 'From com mais de uma base',
{
  prog("Class C From A, B\n  Data x\nEndClass").classes[0].supers.join(',') eq 'A,B'
};
confere 'classe sem From nem membros',
{
  my $c = prog("Class Vazia\nEndClass").classes[0];
  $c.nome eq 'Vazia' && !$c.supers && !$c.atributos && !$c.metodos
};

# ---- '::' -- acesso ao proprio objeto --------------------------------------------
confere ':::aBuf e um Membro cuja base e o proprio objeto',
{
  my $e = expr('::aBuf');
  $e ~~ Membro && $e.base ~~ AutoSelf && $e.nome eq 'aBuf'
};
confere '::Grow() e um metodo do proprio objeto',
{
  my $e = expr('::Grow()');
  $e ~~ Metodo && $e.base ~~ AutoSelf && $e.nome eq 'Grow' && !$e.args
};
confere '::aBuf[::nTail]: indice sobre membro, e o :: nao le variavel',
{
  my $e = expr('::aBuf[::nTail]');
  my @n;
  percorre-expr($e, { @n.push(.nome) if $_ ~~ Nome });
  $e ~~ Indice && $e.base ~~ Membro && @n == 0
};
confere '::nHead := 1: o :: vale como alvo de atribuicao',
{
  my $src = "method f() class C\n  ::nHead := 1\nreturn";
  my $m = prog($src).metodos[0];
  my $a = $m.corpo[0];
  $a ~~ Atribuicao && $a.alvo ~~ Membro && $a.alvo.base ~~ AutoSelf
};
confere '::aBuf[::nTail] := x: alvo com membro e indice',
{
  my $src = "method f() class C\n  ::aBuf[::nTail] := x\nreturn";
  my $a = prog($src).metodos[0].corpo[0];
  $a ~~ Atribuicao && $a.alvo ~~ Indice && $a.alvo.base ~~ Membro
};
confere 'Self ainda e um nome comum, e ::x le o mesmo objeto sem ler variavel',
{
  expr('Self') ~~ Nome && !expr('::x').base.isa(Nome)
};

# ---- o que tem de ser recusado -------------------------------------------------------
my @recusar =
  "class C\n  data x"                          => 'classe sem endclass',
  "method f(x) class"                          => 'implementacao sem o nome da classe',
  "Class C\n  Data\nEndClass"                  => 'data sem nome',
  "Class C\n  Method\nEndClass"                => 'method sem nome',
  "::"                                         => 'dois-pontos sem membro',
  ;

for @recusar -> $c
{
  confere "recusa: {$c.value}", { !casa($c.key) };
}

say "\n  $ok de $total";
exit($ok == $total ?? 0 !! 1);
