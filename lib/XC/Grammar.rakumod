# XC::Grammar -- uma gramatica de TL++, com o xtpl crescendo dela.
#
# ALVO: TL++, NAO AdvPL
#
# A diferenca importa. TL++ tem 'namespace', tem anotacoes, e tem tipos
# declarados. Uma gramatica que tentasse cobrir os dois teria de aceitar tudo
# que o AdvPL aceita e mais, e nao poderia recusar nada -- que e como se
# chega de volta a expressao regular.
#
# ALTERNACAO ORDENADA EM TODO LUGAR
#
# Este arquivo usa '||' e nunca '|'. Duas razoes, e as duas contam.
#
# A primeira e de projeto: numa gramatica de linguagem a ordem das
# alternativas E a especificacao. 'declaracao || atribuicao' diz que uma linha
# que pode ser as duas coisas e uma declaracao. O '|' do Raku escolhe a mais
# longa, que e uma regra sobre o texto e nao sobre a linguagem.
#
# A segunda e que o '|' do rakupp 4.0.1 tem um defeito: uma alternativa que
# contem uma sub-regra quantificada com separador -- '<expr>* % ","' -- falha
# dentro de uma alternancia, e casa sozinha. Menor caso:
#
#     rule  call { <name> "(" <expr>* % "," ")" }
#     rule  asg  { <name> ":=" \d+ }
#     rule  alt  { <call> | <asg> }       # nao casa 'f("a")'
#     rule  alt2 { <call> || <asg> }      # casa
#
# Com '||' funciona. Como '||' e o que se quer de qualquer jeito, isto nao e
# uma concessao.

unit grammar XC::Grammar;

# UM COMANDO POR LINHA
#
# Em AdvPL a quebra de linha termina o comando, a nao ser que a linha acabe
# em ';'. Aqui ja foi so espaco, e isso deixava um comando continuar na linha
# de baixo:
#
#     return                    o valor do return virava 'endif', e o
#   endif                       arquivo inteiro deixava de casar
#
#     return                    o valor virava 'user', e a funcao seguinte
#                               passava a ser um 'function g()' sem 'user'
#   user function g()           -- esta calada
#
# Entao '<.ws>' nao atravessa linha, e cada lugar onde uma linha pode acabar
# diz isso com '<.nl>'. Linhas em branco e so de comentario ficam dentro do
# '<.nl>', e nao sao comandos.
rule TOP
{
  ^ <.gap> [ <toplevel> <.gap> ]* $
}

# A funcao primeiro: ela comeca pelas suas anotacoes, e so se o que segue nao
# for uma funcao a anotacao fica sozinha.
rule toplevel
{
     <function>
  || [ [ <preproc> || <namespacest> || <annotation> ] <.eol> ]
}

# ---- o que o pre-processador leva inteiro ---------------------------------
# Uma diretiva vai inteira para o pre-processador do TL++ -- '#include',
# '#define', '#command', '#xtranslate'. Nada aqui olha o que ha dentro: a
# definicao de um '#command' e uma linguagem propria, e nao e a nossa.
#
# Mas ela pode CONTINUAR: uma linha terminada em ';' segue na proxima, e um
# '#xtranslate' com corpo costuma ocupar tres ou quatro.
token preproc
{
  # O '\N*?' e frugal de proposito: o guloso come o proprio ';' e depois nao
  # tem o que casar.
  '#' [ \N*? ';' \h* \n ]* \N*
}

# ---- TL++: namespace -------------------------------------------------------
rule namespacest
{
  :i [ 'using' 'namespace' || 'namespace' ] <dottedname>
}

token dottedname { <[A..Za..z_]> \w* [ '.' <[A..Za..z_]> \w* ]* }

# ---- TL++: anotacoes -------------------------------------------------------
#
# Uma linha que comeca com '@'. Pode ou nao levar argumentos entre
# parenteses, e vem antes do que anota.
rule annotation
{
  '@' <name> [ '(' ~ ')' <arglist> ]?
}

# ---- funcoes ---------------------------------------------------------------
rule function
{
  [ <annotation> <.nl> ]*
  <funckind> <name> '(' ~ ')' <params> <.nl>
  <body>
}

# O 'function' solto e aceito de proposito. O AdvPL o recusa ("Regular
# functions are not allowed in code"), mas o TL++ aceita quando o nome comeca
# com 'u_' -- e talvez com outros prefixos, que nao estao levantados. Recusar
# aqui seria recusar TL++ valido.
token funckind { :i [ [ 'user' || 'static' || 'main' ] \s+ ]? 'function' }

rule params
{
  <param>? [ ',' <param>? ]*
}

# Um parametro tambem pode ser tipado: 'f(nX as Numeric)'.
rule param
{
  <name> <typespec>?
}

# 'return' e um COMANDO, nao so o fim da funcao. Um return antecipado dentro
# de um 'if' e corrente, e se o 'return' final fosse parte da regra da funcao,
# o corpo engoliria os de dentro e sobraria nada para fechar.
rule returnst
{
  :i 'return' <expr>?
}

rule exitst { :i 'exit' }
rule loopst { :i 'loop' }

# Cada comando termina a sua linha. O corpo para no primeiro que nao casa --
# 'endif', 'next', a proxima 'function' -- e quem o chamou decide o que e.
rule body
{
  [ <statement> <.nl> ]*
}

# ---- tipos ------------------------------------------------------------------
#
# O tipo pode vir declarado ou sair do inicializador:
#
#     local aLista := {}              implicito
#     local aLista as Array           explicito
#     local aLista := {} as Array     os dois, e tem de bater
#
# Os nomes abreviam para a primeira letra: 'as A' e 'as Array'.
rule typespec
{
  :i 'as' <typename>
}

token typename
{
  :i [
       'array'     || 'a' >>
    || 'numeric'   || 'n' >>
    || 'character' || 'c' >>
    || 'logical'   || 'l' >>
    || 'date'      || 'd' >>
    || 'object'    || 'o' >>
    || 'block'     || 'b' >>
    || 'json'      || 'j' >>
    || 'variant'   || 'u' >>
  ]
}

# ---- comandos ---------------------------------------------------------------
rule statement
{
     <annotation>
  || <returnst>
  || <exitst>
  || <loopst>
  || <seqst>
  || <declaration>
  || <ifst>
  || <whilest>
  || <forst>
  || <docasest>
  || <assignment>
  || <callst>
}

token blockcomment { '/*' .*? '*/' }

rule declaration
{
  <declkind> <declarator>+ % ','
}

rule declkind { :i [ 'local' || 'private' || 'public' || 'static' ] }

# O tipo vem DEPOIS do inicializador, e so:
#
#     local nX := 1 as Numeric        certo
#     local nX as Numeric             certo, sem inicializador
#     local nX as Numeric := 1        RECUSADO
#
# A segunda ordem chegou a estar aqui, com um comentario dizendo que o TL++
# aceitava as duas. Ninguem tinha conferido. Uma gramatica que aceita mais do
# que a linguagem nao pode recusar nada, que e o defeito que ela existe para
# corrigir.
rule declarator
{
     [ <name> ':=' <expr> <typespec>? ]
  || [ <name> <typespec> ]
  || <name>
}

# As partes levam nome -- '<cond=expr>', '<corpo=body>' -- porque as
# repetidas voltam como lista, e sem nome o corpo do 'else' seria so o ultimo
# de uma lista que as vezes tem um a mais.
rule ifst
{
  :i 'if' <cond=expr> <.nl>
     <corpo=body>
  [ :i 'elseif' <cond=expr> <.nl> <corpo=body> ]*
  [ :i 'else' <.nl> <senao=body> ]?
  :i 'endif'
}

rule whilest
{
  :i 'while' <cond=expr> <.nl>
     <corpo=body>
  :i [ 'enddo' || 'end' ]
}

rule forst
{
  :i 'for' <var=name> ':=' <de=expr> :i 'to' <ate=expr>
     [ :i 'step' <passo=expr> ]? <.nl>
     <corpo=body>
  :i 'next' <fim=name>?
}

rule docasest
{
  :i 'do' 'case' <.nl>
  [ :i 'case' <cond=expr> <.nl> <corpo=body> ]+
  [ :i 'otherwise' <.nl> <senao=body> ]?
  :i 'endcase'
}

# BEGIN SEQUENCE ... RECOVER ... END SEQUENCE -- o tratamento de erro.
rule seqst
{
  :i 'begin' 'sequence' <.nl>
     <corpo=body>
  [ :i 'recover' [ :i 'using' <erro=name> ]? <.nl> <recupera=body> ]?
  :i 'end' [ :i 'sequence' ]?
}

rule assignment
{
  <!stmtword> <lvalue> <assignop> <expr>
}

token assignop { ':=' || '+=' || '-=' || '*=' || '/=' || '=' }

# Uma chamada de verdade, nao um nome solto: ou tem parenteses, ou tem ao
# menos um ':' / '->' / '[' depois.
#
# E nao pode COMECAR com uma palavra que abre um comando. Sem essa guarda,
# 'return (.t.)' casa como chamada a uma funcao chamada 'return', o corpo
# engole a linha, e a funcao acaba sem o return que a fecha.
#
# A guarda fica aqui e em <assignment>, e nao em <name>: 'If', 'End' e 'Next'
# sao nomes de funcao e de metodo -- 'If(c,a,b)' e o ternario e 'oDlg:End()'
# fecha um dialogo. So o comeco de um comando e reservado.
rule callst
{
  <!stmtword> [ [ <call> <trailer>* ] || [ <name> <trailer>+ ] ]
}

token stmtword
{
  :i [ 'return' || 'local' || 'private' || 'public' || 'static'
    || 'if' || 'elseif' || 'else' || 'endif'
    || 'while' || 'enddo' || 'for' || 'next' || 'exit' || 'loop'
    || 'do' || 'case' || 'endcase' || 'otherwise'
    || 'begin' || 'recover' || 'end'
    || 'namespace' || 'using'
  ] >>
}

# ---- expressoes, por precedencia --------------------------------------------
#
# Cada nivel escrito como 'a [ op a ]*', e nao como 'a+ % op'. Num 'rule',
# o rakupp 4.0.1 nao casa '<n>+ % <op>' quando a entrada tem espacos:
#
#     rule TOP { <n>+ % <op> }          # nao casa '1 + 2 - 3', casa '1+2-3'
#     rule TOP { <n> [ <op> <n> ]* }     # casa os dois
#
# Pode ser defeito ou so o jeito como '%' combina com espaco significativo --
# sem um Rakudo para comparar, nao da para dizer. Com 'token' funciona.
#
# Sem o operador capturado, 'a + b' virava um no de soma com operador vazio,
# e o verificador de tipos nao sabia que era uma soma.
rule expr      { <orexpr> }
rule orexpr    { <andexpr> [ <orop> <andexpr> ]* }
token orop     { :i '.or.' }
rule andexpr   { <notexpr> [ <andop> <notexpr> ]* }
token andop    { :i '.and.' }
rule notexpr   { <negate>? <cmpexpr> }
token negate   { '!' || [ :i '.not.' ] }
rule cmpexpr   { <addexpr> [ <cmpop> <addexpr> ]* }
token cmpop    { '==' || '!=' || '<>' || '>=' || '<=' || '>' || '<' || '$' }
rule addexpr   { <mulexpr> [ <addop> <mulexpr> ]* }
token addop    { '+' || '-' }
rule mulexpr   { <unary> [ <mulop> <unary> ]* }
token mulop    { '*' || '/' || '%' }
rule unary     { <sign>? <postfix> }
token sign     { '-' || '+' }

# Um literal nao leva trailer: string e numero nao tem membro nem indice. Sem
# isso '{ "a": nX }' casava como um ARRAY cujo item era o membro 'nX' da
# string "a" -- o ':' do par virava o de um membro, e o JSON caia para array.
rule postfix
{
     <literal>
  || [ <primary> <trailer>* ]
}

# Uma regra por forma, para a arvore saber qual casou.
rule trailer
{
     <tmetodo>
  || <tmembro>
  || <tindice>
  || <temalias>
  || <tcampo>
}

# ':' seguido de um metodo COM argumentos: 'MSDialog():New(...)'. Antes do
# membro simples, senao ele casaria o nome e deixaria os parenteses para tras.
rule tmetodo  { ':' <member> '(' ~ ')' <arglist> }
rule tmembro  { ':' <member> }
rule tindice  { '[' ~ ']' [ <expr> [ ',' <expr> ]* ] }
rule temalias { '->' '(' ~ ')' <expr> }
rule tcampo   { '->' <member> }

# Depois de ':' ou '->' vem um MEMBRO, e um membro pode chamar-se 'End' ou
# 'Next'. A lista de reservadas vale onde um comando comeca, nao aqui.
token member { <[A..Za..z_]> \w* }

rule primary
{
     <macro>
  || <literal>
  || <codeblock>
  || <jsonliteral>
  || <hashliteral>
  || <arrayliteral>
  || <call>
  || <aliasfield>
  || <name>
  || [ '(' ~ ')' <expr> ]
}

# O operador macro: '&(expressao)' ou '&nome'. Compila e roda a string em
# tempo de execucao -- nada aqui enxerga o que ha dentro.
rule macro
{
  '&' [ [ '(' ~ ')' <expr> ] || <name> ]
}

rule call        { <name> '(' ~ ')' <arglist> }

# Uma posicao por virgula, vazia ou nao: 'f( , 1, , )' tem quatro, e a arvore
# precisa saber em qual o '1' esta. Escrito a mao em vez de com '%': um item
# que pode casar vazio dentro de um '*' para na primeira volta, e ai ',1' nao
# casa.
rule arglist     { <slot> [ ',' <slot> ]* }
rule slot        { <arg>? }

# Uma atribuicao tambem e um argumento valido: 'If( c, a, cA := u )'.
rule arg         { <byref> || <assignment> || <expr> }
rule byref       { '@' <name> }

# 'SA1->A1_NOME' e 'SA1->( DbGoTop() )'. O 'SA1' e o NOME de uma area, nao uma
# variavel: com variavel se escreve '(cAlias)->A1_NOME', que e um primario
# entre parenteses seguido de um trailer.
rule aliasfield  { <alias=name> '->' [ [ '(' ~ ')' <expr> ] || <campo=member> ] }

# '{ : }' e o JSON vazio e '{ => }' o hash vazio. Precisam de grafia propria
# porque '{}' ja quer dizer array vazio -- e tem de vir ANTES de
# <arrayliteral>, que casaria as chaves e deixaria o ':' para tras.
# Pelo menos um par, ou o ':' do vazio. Com '<pair>*' um '{}' sem nada
# dentro casava aqui -- e esta regra vem antes de <arrayliteral>, entao todo
# array vazio virava JSON.
rule jsonliteral { '{' ~ '}' [ ':' || [ <pair>+ % ',' ] ] }
rule hashliteral { '{' ~ '}' [ '=>' || [ <hashpair>+ % ',' ] ] }
rule pair        { <expr> ':' <expr> }
rule hashpair    { <expr> '=>' <expr> }
rule arrayliteral { '{' ~ '}' [ <expr>* % ',' ] }

# '{ || ... }' e um bloco sem parametros, e os dois pipes ficam colados.
rule codeblock
{
  '{' [ '||' || [ '|' <name>* % ',' '|' ] ] <blockexpr>* % ',' '}'
}

# Dentro de um code block a atribuicao E uma expressao.
rule blockexpr   { <assignment> || <expr> }

rule lvalue      { <name> <trailer>* }

# ---- terminais ---------------------------------------------------------------
token literal  { <number> || <string> || <logical> || <nildef> }
token number   { \d+ [ '.' \d+ ]? }
token string   { [ '"' <-["]>* '"' ] || [ "'" <-[']>* "'" ] }
token logical  { :i '.t.' || '.f.' }
token nildef   { :i 'nil' >> }
token name     { <[A..Za..z_]> \w* }

# Espaco DENTRO de uma linha: brancos, comentarios, e a continuacao ';' --
# que e o unico jeito de um comando seguir na linha de baixo.
token ws { <!ww> [ \h || <.linecont> || <.linecomment> || <.blockcomment> ]* }
token linecont    { ';' \h* \v }
token linecomment { '//' \N* }

# O fim de uma linha (ou do arquivo), e o que vier ate o proximo comando:
# linhas em branco, linhas so de comentario, e o recuo.
token eol { \h* [ <.linecomment> || <.blockcomment> ]? \h* [ \v || $ ] }
token gap { [ \s || <.linecont> || <.linecomment> || <.blockcomment> ]* }
token nl  { <.eol> <.gap> }
