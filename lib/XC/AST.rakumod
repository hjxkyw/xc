# XC::AST -- a arvore que a gramatica produz.
#
# Cada no e uma classe pequena com o que importa daquele pedaco do programa,
# e nada da sintaxe que o escreveu. 'local nX := 1 as N' e
# 'local nX := 1 as Numeric' viram o mesmo no: a abreviacao e grafia.
#
# Por enquanto so declaracoes e expressoes. O resto da gramatica casa e nao
# produz nada ainda -- vira no quando algo precisar dele.

unit module XC::AST;

# Os tipos do TL++, pelo nome inteiro. A gramatica aceita a abreviacao; a
# arvore guarda sempre o nome, para quem ler nao ter de saber que 'N' e
# 'Numeric'.
#
# Strings, e nao um 'enum'. 'Array', 'Numeric', 'Date' e 'Block' ja sao
# tipos do proprio Raku, e um enum com essas chaves nao ganha deles: o nome
# continua sendo o tipo do Raku, que dentro de uma string sai vazio. O erro
# foi meu, nao do rakupp.
constant @TIPOS is export =
  <Array Numeric Character Logical Date Object Block JSON Variant>;

constant DESCONHECIDO is export = '?';

sub tipo-de-nome(Str $nome --> Str) is export
{
  given $nome.lc
  {
    when 'array'     | 'a' { 'Array'     }
    when 'numeric'   | 'n' { 'Numeric'   }
    when 'character' | 'c' { 'Character' }
    when 'logical'   | 'l' { 'Logical'   }
    when 'date'      | 'd' { 'Date'      }
    when 'object'    | 'o' { 'Object'    }
    when 'block'     | 'b' { 'Block'     }
    when 'json'      | 'j' { 'JSON'      }
    when 'variant'   | 'u' { 'Variant'   }
    default                { DESCONHECIDO }
  }
}

# ---- expressoes ---------------------------------------------------------------
class Expr is export
{
  has Int $.linha is rw = 0;
}

class Literal is Expr is export
{
  has Str  $.tipo;
  has Str  $.texto;
}

class Nome is Expr is export
{
  has Str $.nome;
}

class Chamada is Expr is export
{
  has Str  $.nome;
  has Expr @.args;
}

class Binaria is Expr is export
{
  has Str  $.op;
  has Expr $.esq;
  has Expr $.dir;
}

# O que ainda nao vira no: fica o texto, para nao se perder.
class Opaca is Expr is export
{
  has Str $.texto;
}

# ---- declaracoes --------------------------------------------------------------
class Declarador is export
{
  has Str   $.nome;
  has Expr  $.inicial;         # Nil se nao tem
  has Str   $.declarado;       # o 'as ...', ou '?' se nao tem
  has Int   $.linha;
}

class Declaracao is export
{
  has Str        $.escopo;     # local, private, public, static
  has Declarador @.nomes;
}
