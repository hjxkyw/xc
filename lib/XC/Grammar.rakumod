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

rule TOP
{
  <toplevel>*
}

rule toplevel
{
     <preproc>
  || <namespacest>
  || <docblock>
  || <blockcomment>
  || <annotation>
  || <function>
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
  ^^ \h* '#' [ \N*? ';' \h* \n ]* \N*
}
token docblock { '/*/' .*? '/*/' }

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
  ^^ \h* '@' <name> [ '(' ~ ')' <arglist> ]?
}

# ---- funcoes ---------------------------------------------------------------
rule function
{
  <annotation>*
  <funckind> <name> '(' ~ ')' <params>
  <body>
  <returnst>
}

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

rule returnst
{
  :i 'return' <expr>?
}

rule body
{
  <statement>*
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
     <comment>
  || <annotation>
  || <seqst>
  || <declaration>
  || <ifst>
  || <whilest>
  || <forst>
  || <docasest>
  || <assignment>
  || <callst>
}

token comment { <linecomment> || <blockcomment> }
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

rule ifst
{
  :i 'if' <expr>
     <body>
  [ :i 'elseif' <expr> <body> ]*
  [ :i 'else' <body> ]?
  :i 'endif'
}

rule whilest
{
  :i 'while' <expr>
     <body>
  :i [ 'enddo' || 'end' ]
}

rule forst
{
  :i 'for' <name> ':=' <expr> :i 'to' <expr> [ :i 'step' <expr> ]?
     <body>
  :i 'next' <name>?
}

rule docasest
{
  :i 'do' 'case'
  [ :i 'case' <expr> <body> ]+
  [ :i 'otherwise' <body> ]?
  :i 'endcase'
}

# BEGIN SEQUENCE ... RECOVER ... END SEQUENCE -- o tratamento de erro.
rule seqst
{
  :i 'begin' 'sequence'
     <body>
  [ :i 'recover' [ :i 'using' <name> ]? <body> ]?
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
rule expr      { <orexpr> }
rule orexpr    { <andexpr>+   % [ :i '.or.' ] }
rule andexpr   { <notexpr>+   % [ :i '.and.' ] }
rule notexpr   { <negate>? <cmpexpr> }
token negate   { '!' || [ :i '.not.' ] }
rule cmpexpr   { <addexpr>+   % <cmpop> }
token cmpop    { '==' || '!=' || '<>' || '>=' || '<=' || '>' || '<' || '$' }
rule addexpr   { <mulexpr>+   % <addop> }
token addop    { '+' || '-' }
rule mulexpr   { <unary>+     % <mulop> }
token mulop    { '*' || '/' || '%' }
rule unary     { <sign>? <postfix> }
token sign     { '-' || '+' }

rule postfix
{
  <primary> <trailer>*
}

rule trailer
{
     # ':' seguido de um metodo COM argumentos: 'MSDialog():New(...)'.
     # Primeiro esta forma, senao a de um membro simples casaria o nome e
     # deixaria os parenteses para tras.
     [ ':' <member> '(' ~ ')' <arglist> ]
  || [ ':' <member> ]
  || [ '[' ~ ']' <expr>+ % ',' ]
  || [ '->' <member> ]
}

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

# Escrito a mao em vez de '[ <arg>? ]* % ","': um item que pode casar vazio
# dentro de um '*' para na primeira volta, e ai ',1' nao casa.
rule arglist     { <arg>? [ ',' <arg>? ]* }

# Uma atribuicao tambem e um argumento valido: 'If( c, a, cA := u )'.
rule arg         { [ '@' <name> ] || <assignment> || <expr> }

rule aliasfield  { <name> '->' [ [ '(' ~ ')' <expr> ] || <member> ] }

# '{ : }' e o JSON vazio e '{ => }' o hash vazio. Precisam de grafia propria
# porque '{}' ja quer dizer array vazio -- e tem de vir ANTES de
# <arrayliteral>, que casaria as chaves e deixaria o ':' para tras.
rule jsonliteral { '{' ~ '}' [ ':' || [ <pair>* % ',' ] ] }
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

# Espaco: brancos, comentarios de linha e a continuacao ';'
token ws { <!ww> [ \h || <.linecont> || <.linecomment> || \v ]* }
token linecont    { ';' \h* \v }
token linecomment { '//' \N* }
