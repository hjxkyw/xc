# XC::AST -- a arvore que a gramatica produz.
#
# Cada no e uma classe pequena com o que importa daquele pedaco do programa,
# e nada da sintaxe que o escreveu. 'local nX := 1 as N' e
# 'local nX := 1 as Numeric' viram o mesmo no: a abreviacao e grafia.
#
# Expressoes, comandos, funcoes e o arquivo. Dentro de uma expressao, o que
# ainda nao tem no proprio -- 'o:x(1)[2]', um code block -- fica como texto
# (Opaca, ou o texto de um Literal), mas nenhum COMANDO fica sem no: um corpo
# e a lista inteira dos comandos que ele tem, em ordem.

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

# ---- comandos -------------------------------------------------------------------
#
# Um corpo e um array de Cmd. As partes opcionais que faltam ficam com o objeto
# de tipo -- 'Expr' sem valor --, que e o que '.defined' responde como falso.
class Cmd is export
{
  has Int $.linha = 0;
}

class Declarador is export
{
  has Str   $.nome;
  has Expr  $.inicial;         # indefinido se nao tem
  has Str   $.declarado;       # o 'as ...', ou '?' se nao tem
  has Int   $.linha;
}

class Declaracao is Cmd is export
{
  has Str        $.escopo;     # local, private, public, static
  has Declarador @.nomes;
}

# 'n := 1', 'n += 1', 'o:x := 2'. O alvo e um Nome, ou Opaca quando tem
# trailer.
class Atribuicao is Cmd is export
{
  has Expr $.alvo;
  has Str  $.op;
  has Expr $.valor;
}

# Uma chamada como comando: 'conout(x)', 'oDlg:Activate()'.
class ChamadaCmd is Cmd is export
{
  has Expr $.chamada;
}

class Retorno  is Cmd is export { has Expr $.valor; }   # indefinido: 'return'
class Sai      is Cmd is export { }                      # exit
class Continua is Cmd is export { }                      # loop

class Anotacao is Cmd is export
{
  has Str  $.nome;
  has Expr @.args;
}

# Uma condicao e o que roda quando ela vale. 'if/elseif' e 'do case' sao a
# mesma coisa: ramos em ordem, e o que sobra.
class Ramo is export
{
  has Expr $.cond;
  has Cmd  @.corpo;
}

class Se is Cmd is export
{
  has Ramo @.ramos;            # o 'if' e cada 'elseif'
  has Cmd  @.senao;
}

class Caso is Cmd is export
{
  has Ramo @.ramos;            # cada 'case'
  has Cmd  @.senao;            # 'otherwise'
}

class Enquanto is Cmd is export
{
  has Expr $.cond;
  has Cmd  @.corpo;
}

class Para is Cmd is export
{
  has Str  $.var;
  has Expr $.de;
  has Expr $.ate;
  has Expr $.passo;            # indefinido: passo 1
  has Cmd  @.corpo;
}

class Sequencia is Cmd is export
{
  has Cmd  @.corpo;
  has Bool $.tem-recover = False;
  has Str  $.erro;             # 'recover using oErr', indefinido se nao tem
  has Cmd  @.recupera;
}

# ---- o arquivo ------------------------------------------------------------------
class Parametro is export
{
  has Str $.nome;
  has Str $.declarado;         # '?' se nao tem
}

class Funcao is export
{
  has Str       $.tipo;         # user, static, main -- ou '' para o 'function' solto
  has Str       $.nome;
  has Parametro @.params;
  has Anotacao  @.anotacoes;
  has Cmd       @.corpo;
  has Int       $.linha;
}

class Programa is export
{
  has Str      $.namespace;    # indefinido se nao tem
  has Str      @.usings;
  has Str      @.diretivas;    # '#include ...' inteiro, como veio
  has Anotacao @.anotacoes;    # as que nao estao antes de uma funcao
  has Funcao   @.funcoes;
}

# ---- percorrer -------------------------------------------------------------------
#
# Os corpos que um comando tem dentro, em ordem de leitura. E o que qualquer
# analise precisa para descer na arvore sem saber de cada tipo de comando.
sub corpos-de(Cmd $c --> List) is export
{
  given $c
  {
    when Se | Caso  { (|.ramos.map({ .corpo.List }), .senao.List).List }
    when Enquanto   { (.corpo.List,).List }
    when Para       { (.corpo.List,).List }
    when Sequencia  { (.corpo.List, .recupera.List).List }
    default         { ().List }
  }
}

# Chama &f em cada comando de um corpo, e nos de dentro, em ordem de leitura.
sub percorre(@corpo, &f) is export
{
  for @corpo -> $c
  {
    f($c);
    percorre($_, &f) for corpos-de($c);
  }
}
