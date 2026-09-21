# XC::Actions -- o que transforma um casamento da gramatica em arvore.
#
# Um metodo por regra que produz no. Um comando sem metodo nao some calado:
# 'statement' morre dizendo qual foi, porque um corpo com um comando a menos
# e uma arvore errada que parece certa.

use XC::AST;

unit class XC::Actions;

# O texto inteiro, para saber em que linha cada no esta:
#
#     XC::Grammar.parse($src, actions => XC::Actions.new(fonte => $src))
#
# Tem de vir de fora porque no rakupp 4.0.1 '$/.orig' e so o texto casado, e
# nao o alvo inteiro como no Rakudo -- e nenhum outro metodo do casamento o
# devolve. A versao anterior contava as linhas de '.orig' e dava sempre uma
# posicao relativa; ninguem viu porque todo teste tinha uma linha so.
has Str $.fonte;
has Int @!quebras;             # a posicao de cada '\n', em ordem

submethod TWEAK()
{
  with $!fonte
  {
    my $i = 0;
    while (my $p = $!fonte.index("\n", $i)).defined
    {
      @!quebras.push($p);
      $i = $p + 1;
    }
  }
}

# A linha de um casamento: quantas quebras vem antes dele, mais um.
method !linha($m --> Int)
{
  die "XC::Actions precisa do texto: XC::Actions.new(fonte => \$src)"
    without $!fonte;
  my $alvo = $m.from;
  my ($lo, $hi) = 0, +@!quebras;       # busca binaria: quebras < $alvo
  while $lo < $hi
  {
    my $mid = ($lo + $hi) div 2;
    if @!quebras[$mid] < $alvo { $lo = $mid + 1 } else { $hi = $mid }
  }
  $lo + 1
}

# ---- o arquivo ------------------------------------------------------------------
method TOP($/)
{
  my ($ns, @usings, @diretivas, @anotacoes, @funcoes);
  for $<toplevel> -> $t
  {
    if $t<function>
    {
      @funcoes.push($t<function>.made);
    }
    elsif $t<preproc>
    {
      @diretivas.push((~$t<preproc>).trim);
    }
    elsif $t<annotation>
    {
      @anotacoes.push($t<annotation>.made);
    }
    elsif $t<namespacest>
    {
      my $n = $t<namespacest>;
      if (~$n).trim.lc.starts-with('using')
      {
        @usings.push(~$n<dottedname>);
      }
      else
      {
        $ns = ~$n<dottedname>;
      }
    }
  }
  make Programa.new(
    namespace => $ns,
    usings    => @usings,
    diretivas => @diretivas,
    anotacoes => @anotacoes,
    funcoes   => @funcoes,
  );
}

method function($/)
{
  my @w = (~$<funckind>).lc.words;
  make Funcao.new(
    tipo      => @w > 1 ?? @w[0] !! '',
    nome      => ~$<name>,
    params    => $<params><param>.map(*.made).list,
    anotacoes => $<annotation>.map(*.made).list,
    corpo     => $<body>.made,
    linha     => self!linha($<funckind>),
  );
}

method param($/)
{
  make Parametro.new(
    nome      => ~$<name>,
    declarado => $<typespec> ?? tipo-de-nome(~$<typespec><typename>)
                             !! DESCONHECIDO,
  );
}

method annotation($/)
{
  make Anotacao.new(
    nome  => ~$<name>,
    args  => $<arglist> ?? $<arglist><arg>.map(*.made).list !! (),
    linha => self!linha($/),
  );
}

# ---- comandos -------------------------------------------------------------------
method body($/)
{
  make $<statement>.map(*.made).list;
}

# Quem casou e o unico filho: a alternancia e ordenada, so um lado vinga.
method statement($/)
{
  my $filho = $/.hash.values[0];
  my $no = $filho.made;
  die "sem no para '{$/.hash.keys[0]}': {(~$/).trim}" without $no;
  make $no;
}

method returnst($/)
{
  make Retorno.new(valor => $<expr> ?? $<expr>.made !! Expr,
                   linha => self!linha($/));
}

method exitst($/) { make Sai.new(linha => self!linha($/)) }
method loopst($/) { make Continua.new(linha => self!linha($/)) }

method assignment($/)
{
  make Atribuicao.new(
    alvo  => $<lvalue>.made,
    op    => ~$<assignop>,
    valor => $<expr>.made,
    linha => self!linha($/),
  );
}

method lvalue($/)
{
  make $<trailer>.elems ?? Opaca.new(texto => (~$/).trim)
                        !! Nome.new(nome => ~$<name>);
}

method callst($/)
{
  make ChamadaCmd.new(
    chamada => ($<call> && !$<trailer>.elems) ?? $<call>.made
                                               !! Opaca.new(texto => (~$/).trim),
    linha   => self!linha($/),
  );
}

method ifst($/)
{
  make Se.new(
    ramos => ramos($<cond>, $<corpo>),
    senao => $<senao> ?? $<senao>.made !! (),
    linha => self!linha($/),
  );
}

method docasest($/)
{
  make Caso.new(
    ramos => ramos($<cond>, $<corpo>),
    senao => $<senao> ?? $<senao>.made !! (),
    linha => self!linha($/),
  );
}

method whilest($/)
{
  make Enquanto.new(
    cond  => $<cond>.made,
    corpo => $<corpo>.made,
    linha => self!linha($/),
  );
}

method forst($/)
{
  make Para.new(
    var   => ~$<var>,
    de    => $<de>.made,
    ate   => $<ate>.made,
    passo => $<passo> ?? $<passo>.made !! Expr,
    corpo => $<corpo>.made,
    linha => self!linha($/),
  );
}

method seqst($/)
{
  make Sequencia.new(
    corpo       => $<corpo>.made,
    tem-recover => ?$<recupera>,
    erro        => $<erro> ?? ~$<erro> !! Str,
    recupera    => $<recupera> ?? $<recupera>.made !! (),
    linha       => self!linha($/),
  );
}

# ---- declaracoes --------------------------------------------------------------
method declaration($/)
{
  make Declaracao.new(
    escopo => ~$<declkind>.lc.trim,
    nomes  => $<declarator>.map(*.made).list,
    linha  => self!linha($/),
  );
}

method declarator($/)
{
  make Declarador.new(
    nome      => ~$<name>,
    inicial   => $<expr> ?? $<expr>.made !! Expr,
    declarado => $<typespec> ?? tipo-de-nome(~$<typespec><typename>)
                             !! DESCONHECIDO,
    linha     => self!linha($/),
  );
}

# ---- expressoes: descendo a precedencia ------------------------------------
#
# Cada nivel com um so filho passa o filho adiante. Um 'orexpr' que e so um
# 'andexpr' nao e um 'ou' de nada, e nao deve virar um no de 'ou'.
method expr($/)    { make $<orexpr>.made }
method orexpr($/)  { make dobra-com-ops($/, 'andexpr', 'orop') }
method andexpr($/) { make dobra-com-ops($/, 'notexpr', 'andop') }

method notexpr($/)
{
  make $<negate> ?? Binaria.new(op => '!', esq => Expr, dir => $<cmpexpr>.made)
                 !! $<cmpexpr>.made;
}

method cmpexpr($/) { make dobra-com-ops($/, 'addexpr', 'cmpop') }
method addexpr($/) { make dobra-com-ops($/, 'mulexpr', 'addop') }
method mulexpr($/) { make dobra-com-ops($/, 'unary',   'mulop') }

method unary($/)
{
  make $<sign> && ~$<sign> eq '-'
    ?? Binaria.new(op => 'neg', esq => Expr, dir => $<postfix>.made)
    !! $<postfix>.made;
}

# Por enquanto, um 'postfix' com trailers vira texto opaco: 'o:x(1)[2]' e
# uma cadeia que ainda nao tem no. Sem trailer, e so o primario.
method postfix($/)
{
  make $<trailer>.elems ?? Opaca.new(texto => ~$/.trim) !! $<primary>.made;
}

method primary($/)
{
  make   $<literal>      ?? $<literal>.made
      !! $<call>         ?? $<call>.made
      !! $<name>         ?? Nome.new(nome => ~$<name>)
      !! $<jsonliteral>  ?? Literal.new(tipo => 'JSON',  texto => ~$/.trim)
      !! $<hashliteral>  ?? Literal.new(tipo => 'Object', texto => ~$/.trim)
      !! $<arrayliteral> ?? Literal.new(tipo => 'Array', texto => ~$/.trim)
      !! $<codeblock>    ?? Literal.new(tipo => 'Block', texto => ~$/.trim)
      !! $<expr>         ?? $<expr>.made
      !!                    Opaca.new(texto => ~$/.trim);
}

method call($/)
{
  make Chamada.new(
    nome => ~$<name>,
    args => $<arglist><arg>.map({ .made // Opaca.new(texto => ~$_) }).list,
  );
}

method arg($/)
{
  make $<expr> ?? $<expr>.made !! Opaca.new(texto => ~$/.trim);
}

method literal($/)
{
  make Literal.new(
    tipo  =>   $<number>  ?? 'Numeric'
            !! $<string>  ?? 'Character'
            !! $<logical> ?? 'Logical'
            !! $<nildef>  ?? 'Variant'
            !!               DESCONHECIDO,
    texto => ~$/,
  );
}

# ---- auxiliares ---------------------------------------------------------------

# Condicoes e corpos voltam como duas listas do mesmo tamanho; um ramo e um de
# cada.
sub ramos($conds, $corpos)
{
  my @c = $conds.list;
  my @b = $corpos.list;
  (^@c).map({ Ramo.new(cond => @c[$_].made, corpo => @b[$_].made) }).list
}

# 'a .or. b .or. c' com um so operador: dobra da esquerda.
sub dobra($/, Str $filho, Str $op)
{
  my @partes = $/{$filho}.map(*.made);
  return @partes[0] if @partes == 1;
  my $acc = @partes.shift;
  $acc = Binaria.new(op => $op, esq => $acc, dir => $_) for @partes;
  $acc
}

# 'a + b - c' com o operador de cada volta.
sub dobra-com-ops($/, Str $filho, Str $opnome)
{
  my @partes = $/{$filho}.map(*.made);
  return @partes[0] if @partes == 1;
  my @ops = $/{$opnome}.map({ (~$_).lc });
  my $acc = @partes.shift;
  for @partes.kv -> $i, $d
  {
    $acc = Binaria.new(op => @ops[$i], esq => $acc, dir => $d);
  }
  $acc
}
