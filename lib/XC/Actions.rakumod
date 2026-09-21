# XC::Actions -- o que transforma um casamento da gramatica em arvore.
#
# Um metodo por regra que produz no. As regras sem metodo aqui continuam
# casando -- so nao produzem nada ainda.

use XC::AST;

unit class XC::Actions;

# O numero da linha de um casamento, contado do comeco do texto.
sub linha-de($m --> Int)
{
  $m.orig.substr(0, $m.from).lines.elems || 1
}

# ---- declaracoes --------------------------------------------------------------
method declaration($/)
{
  make Declaracao.new(
    escopo => ~$<declkind>.lc.trim,
    nomes  => $<declarator>.map(*.made).list,
  );
}

method declarator($/)
{
  make Declarador.new(
    nome      => ~$<name>,
    inicial   => $<expr> ?? $<expr>.made !! Expr,
    declarado => $<typespec> ?? tipo-de-nome(~$<typespec><typename>)
                             !! DESCONHECIDO,
    linha     => linha-de($/),
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
