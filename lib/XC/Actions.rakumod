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
    args  => $<arglist> ?? $<arglist>.made !! (),
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
  make aplica(Nome.new(nome => ~$<name>), $<trailer>);
}

method callst($/)
{
  my $base = $<call> ?? $<call>.made !! Nome.new(nome => ~$<name>);
  make ChamadaCmd.new(
    chamada => aplica($base, $<trailer>),
    linha   => self!linha($/),
  );
}

method ifst($/)
{
  make Se.new(
    ramos   => ramos($<cond>, $<corpo>),
    senao   => $<senao> ?? $<senao>.made !! (),
    hdrdecl => $<hdrdecl> ?? $<hdrdecl>.made !! Declarador,
    linha   => self!linha($/),
  );
}

method docasest($/)
{
  my ($decl, $atrib);
  with $<sujeito>
  {
    if .<sujlocal> { $decl  = .<hdrdecl>.made }
    else           { $atrib = .<assignment>.made }
  }
  make Caso.new(
    ramos    => ramos($<cond>, $<corpo>),
    senao    => $<senao> ?? $<senao>.made !! (),
    sujdecl  => $decl  // Declarador,
    sujatrib => $atrib // Atribuicao,
    linha    => self!linha($/),
  );
}

method whilest($/)
{
  make Enquanto.new(
    cond    => $<cond>.made,
    corpo   => $<corpo>.made,
    hdrdecl => $<hdrdecl> ?? $<hdrdecl>.made !! Declarador,
    linha   => self!linha($/),
  );
}

method forst($/)
{
  make Para.new(
    var       => ~$<var>,
    var-local => ?$<varlocal>,
    de        => $<de>.made,
    ate       => $<ate>.made,
    passo     => $<passo> ?? $<passo>.made !! Expr,
    corpo     => $<corpo>.made,
    linha     => self!linha($/),
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

method !mkdecl($/)
{
  Declarador.new(
    nome      => ~$<name>,
    inicial   => $<expr> ?? $<expr>.made !! Expr,
    declarado => $<typespec> ?? tipo-de-nome(~$<typespec><typename>)
                             !! DESCONHECIDO,
    linha     => self!linha($/),
  )
}

method declarator($/) { make self!mkdecl($/) }
method hdrdecl($/)    { make self!mkdecl($/) }

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

# Um primario e os trailers dele, de dentro para fora: 'o:x(1)[2]' e o
# Indice de um Metodo de um Nome.
method postfix($/)
{
  make $<literal> ?? $<literal>.made !! aplica($<primary>.made, $<trailer>);
}

# Cada trailer faz uma funcao que recebe o que esta a esquerda dele.
method trailer($/) { make $/.hash.values[0].made }

method tmetodo($/)
{
  my $nome = ~$<member>;
  my @args = $<arglist>.made.list;
  make -> $base { Metodo.new(base => $base, nome => $nome, args => @args) }
}

method tmembro($/)
{
  my $nome = ~$<member>;
  make -> $base { Membro.new(base => $base, nome => $nome) }
}

method tindice($/)
{
  my @i = $<expr>.map(*.made);
  make -> $base { Indice.new(base => $base, indices => @i) }
}

method temalias($/)
{
  my $e = $<expr>.made;
  make -> $base { EmAlias.new(base => $base, expr => $e) }
}

method tcampo($/)
{
  my $nome = ~$<member>;
  make -> $base { CampoAlias.new(base => $base, campo => $nome) }
}

# Sem um else que devolva texto: uma forma nova de primario sem no tem de
# aparecer aqui, e nao virar string calada.
method primary($/)
{
  make   $<literal>      ?? $<literal>.made
      !! $<nscall>       ?? $<nscall>.made
      !! $<call>         ?? $<call>.made
      !! $<name>         ?? Nome.new(nome => ~$<name>)
      !! $<expr>         ?? $<expr>.made
      !! $<macro>        ?? $<macro>.made
      !! $<aliasfield>   ?? $<aliasfield>.made
      !! $<jsonliteral>  ?? $<jsonliteral>.made
      !! $<hashliteral>  ?? $<hashliteral>.made
      !! $<arrayliteral> ?? $<arrayliteral>.made
      !! $<codeblock>    ?? $<codeblock>.made
      !! die "primario sem no: {(~$/).trim}";
}

method macro($/)
{
  make Macro.new(alvo => $<expr> ?? $<expr>.made !! Nome.new(nome => ~$<name>));
}

method aliasfield($/)
{
  make $<expr>
    ?? EmAlias.new(alias => ~$<alias>, expr => $<expr>.made)
    !! CampoAlias.new(alias => ~$<alias>, campo => ~$<campo>);
}

method jsonliteral($/)
{
  make JsonLit.new(tipo => 'JSON', texto => (~$/).trim,
                   pares => $<pair>.map(*.made).list);
}

method hashliteral($/)
{
  make HashLit.new(tipo => 'Object', texto => (~$/).trim,
                   pares => $<hashpair>.map(*.made).list);
}

method pair($/)     { make Par.new(chave => $<expr>[0].made, valor => $<expr>[1].made) }
method hashpair($/) { make Par.new(chave => $<expr>[0].made, valor => $<expr>[1].made) }

method arrayliteral($/)
{
  make ArrayLit.new(tipo => 'Array', texto => (~$/).trim,
                    itens => $<expr>.map(*.made).list);
}

method codeblock($/)
{
  make Bloco.new(tipo => 'Block', texto => (~$/).trim,
                 params => $<name>.map(~*).list,
                 corpo  => $<blockexpr>.map(*.made).list);
}

# Dentro de um bloco e num argumento, a atribuicao e uma expressao.
method blockexpr($/)
{
  make $<assignment> ?? atrib-expr($<assignment>.made) !! $<expr>.made;
}

method call($/)
{
  make Chamada.new(nome => ~$<name>, args => $<arglist>.made.list);
}

# O caminho inteiro e o nome; os pontos ficam nele, e nenhum segmento e uma
# variavel lida (sao partes de namespace), entao percorre-expr nao desce neles.
method nscall($/)
{
  make Chamada.new(nome => ~$<qname>, args => $<arglist>.made.list);
}

# 'f()' tem uma posicao vazia so e nenhum argumento; 'f( , 1)' tem duas, e a
# primeira e Omitido.
method arglist($/)
{
  my @s = $<slot>.map({ .<arg> ?? .<arg>.made !! Omitido.new });
  make (@s == 1 && @s[0] ~~ Omitido) ?? () !! @s.List;
}

method arg($/)
{
  make   $<byref>      ?? Ref.new(alvo => Nome.new(nome => ~$<byref><name>))
      !! $<assignment> ?? atrib-expr($<assignment>.made)
      !!                  $<expr>.made;
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

# Os trailers, em ordem, sobre uma base.
sub aplica(Expr $base, $trailers)
{
  my $e = $base;
  $e = .made()($e) for $trailers.list;
  $e
}

sub atrib-expr(Atribuicao $a)
{
  AtribExpr.new(alvo => $a.alvo, op => $a.op, valor => $a.valor)
}

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
