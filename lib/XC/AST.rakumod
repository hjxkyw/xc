# XC::AST -- a arvore que a gramatica produz.
#
# Cada no e uma classe pequena com o que importa daquele pedaco do programa,
# e nada da sintaxe que o escreveu. 'local nX := 1 as N' e
# 'local nX := 1 as Numeric' viram o mesmo no: a abreviacao e grafia.
#
# Expressoes, comandos, funcoes e o arquivo. Nada fica como texto: todo nome
# que uma expressao le e um no, ate dentro de 'o:x(n)[i]', de um code block ou
# de uma macro. Uma analise que procura quem le uma variavel pode confiar que
# nao ha leitura escondida numa string -- a nao ser a que a propria macro faz
# em tempo de execucao, que nenhuma arvore enxerga.

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

# ---- o que vem depois de uma expressao ----------------------------------------
class Indice is Expr is export           # a[i, j]
{
  has Expr $.base;
  has Expr @.indices;
}

class Membro is Expr is export           # o:nX
{
  has Expr $.base;
  has Str  $.nome;
}

class Metodo is Expr is export           # o:Soma(1, 2)
{
  has Expr $.base;
  has Str  $.nome;
  has Expr @.args;
}

# Um campo de area. 'SA1->A1_NOME' tem a area pelo nome ('alias', e 'base'
# indefinida); '(cAlias)->A1_NOME' tem a area numa expressao ('base').
class CampoAlias is Expr is export
{
  has Expr $.base;
  has Str  $.alias;
  has Str  $.campo;
}

# Uma expressao avaliada numa area: 'SA1->( DbGoTop() )'. Area como acima.
class EmAlias is Expr is export
{
  has Expr $.base;
  has Str  $.alias;
  has Expr $.expr;
}

# ---- o resto ------------------------------------------------------------------
# '&cVar' e '&(cA + cB)'. O 'alvo' e o que da a string -- o Nome 'cVar' e LIDO.
# O que a string faz em tempo de execucao, nada aqui sabe.
class Macro is Expr is export
{
  has Expr $.alvo;
}

class Ref is Expr is export              # '@aX' num argumento: le e escreve
{
  has Expr $.alvo;
}

class Omitido is Expr is export { }      # a posicao vazia de 'f( , 1)'

# Uma atribuicao onde vale uma expressao: 'If(c, a, cA := u)', '{|| n := 1}'.
class AtribExpr is Expr is export
{
  has Expr $.alvo;
  has Str  $.op;
  has Expr $.valor;
}

# Literais com partes. Continuam sendo Literal -- com o tipo e o texto --, para
# quem so quer saber o tipo nao ter de conhecer cada um.
class Par is export
{
  has Expr $.chave;
  has Expr $.valor;
}

class ArrayLit is Literal is export { has Expr @.itens; }
class JsonLit  is Literal is export { has Par  @.pares; }
class HashLit  is Literal is export { has Par  @.pares; }

class Bloco is Literal is export
{
  has Str  @.params;
  has Expr @.corpo;
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

# 'n := 1', 'n += 1', 'o:x := 2'. O alvo e um Nome, ou a cadeia que termina
# no que se escreve: um Indice, um Membro, um CampoAlias.
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
  has Ramo       @.ramos;      # o 'if' e cada 'elseif'
  has Cmd        @.senao;
  has Declarador $.hdrdecl;    # 'if local x := ..., cond', indefinido se nao
}

class Caso is Cmd is export
{
  has Ramo       @.ramos;      # cada 'case'
  has Cmd        @.senao;      # 'otherwise'
  # 'do case with <sujeito>': avaliado uma vez. Com 'local' e um declarador (um
  # local novo); sem, uma atribuicao a uma variavel ja declarada. So um dos dois.
  has Declarador $.sujdecl;
  has Atribuicao $.sujatrib;
}

class Enquanto is Cmd is export
{
  has Expr       $.cond;
  has Cmd        @.corpo;
  has Declarador $.hdrdecl;    # 'while local x := ..., cond', indefinido se nao
}

class Para is Cmd is export
{
  has Str  $.var;
  has Bool $.var-local = False;  # 'for local i := ...': 'i' e um local novo
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

# As expressoes logo abaixo de uma, em ordem de leitura. As partes que faltam
# (o lado vazio de um '!', a base de um 'SA1->') nao aparecem.
sub subexprs(Expr $e --> List) is export
{
  my @s = do given $e
  {
    when Binaria    { .esq, .dir }
    when Chamada    { |.args }
    when Indice     { .base, |.indices }
    when Membro     { .base }
    when Metodo     { .base, |.args }
    when CampoAlias { .base }
    when EmAlias    { .base, .expr }
    when Macro      { .alvo }
    when Ref        { .alvo }
    when AtribExpr  { .alvo, .valor }
    when ArrayLit   { |.itens }
    when JsonLit | HashLit { |.pares.map({ .chave, .valor }).flat }
    when Bloco      { |.corpo }
    default         { () }
  };
  @s.grep(*.defined).List
}

# Chama &f numa expressao e em todas as de dentro, em ordem de leitura.
sub percorre-expr(Expr $e, &f) is export
{
  return without $e;
  f($e);
  percorre-expr($_, &f) for subexprs($e);
}

# As expressoes que um comando tem, sem descer nos corpos -- 'percorre' e que
# desce. A variavel de um 'for' e um nome, nao uma expressao, e fica de fora.
sub exprs-de(Cmd $c --> List) is export
{
  my @s = do given $c
  {
    when Declaracao { |.nomes.map(*.inicial) }
    when Atribuicao { .alvo, .valor }
    when ChamadaCmd { .chamada }
    when Retorno    { .valor }
    when Anotacao   { |.args }
    when Se         { .hdrdecl.defined ?? (.hdrdecl.inicial, |.ramos.map(*.cond)) !! |.ramos.map(*.cond) }
    when Caso       { (.sujdecl.defined  ?? .sujdecl.inicial !! Expr),
                      (.sujatrib.defined ?? .sujatrib.valor  !! Expr),
                      |.ramos.map(*.cond) }
    when Enquanto   { .hdrdecl.defined ?? (.hdrdecl.inicial, .cond) !! .cond }
    when Para       { .de, .ate, .passo }
    default         { () }
  };
  @s.grep(*.defined).List
}
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
