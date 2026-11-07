" Vim syntax file
" Language:  xtpl -- TL++ with xtpl's extensions, the language xc compiles
" Filenames: *.xtpl
" URL:       https://github.com/hjxkyw/xc (editors/vim)
"
" What editors/vscode's grammar colors, as Vim's groups: TL++'s keywords,
" declarations and types; xtpl's own -- '|>' and 'then', the runtime's
" verbs, lambdas ('[x] x * 2'), 'defer', 'using alias', 'with object',
" 'fallback', '?=', '?:', '?.', 'in', 'has', '%%', ranges, '${...}' in
" strings, typed and fixed arrays and hashes, sets and bags, types and their
" fields ('type Item', 'aIt.nQtd'); Clipper's '&&'
" and '*' comments; the preprocessor's directives. A string ends at its
" quote or at the end of its line, as TL++'s: nothing but a block comment,
" or a directive carried on with ';', goes past a line.

if exists("b:current_syntax")
  finish
endif

let s:cpo_save = &cpo
set cpo&vim

syn case ignore

" ---- comments ----------------------------------------------------------------
syn case match
syn keyword xtplTodo contained TODO FIXME XXX NOTE
syn case ignore
syn match xtplComment "//.*$" contains=xtplTodo,@Spell
syn match xtplComment "&&.*$" contains=xtplTodo,@Spell
syn match xtplComment "^\s*\*.*$" contains=xtplTodo,@Spell
syn region xtplCommentBlock start="/\*" end="\*/" contains=xtplTodo,@Spell

" ---- the preprocessor --------------------------------------------------------
syn match xtplInclude "^\s*#\s*include\>" nextgroup=xtplIncludeFile skipwhite
syn match xtplIncludeFile +"[^"]*"\|<[^>]*>\|'[^']*'+ contained
syn region xtplDirective matchgroup=xtplPreProc
      \ start="^\s*#\s*\%(define\|undef\|ifdef\|ifndef\|if\|elif\|else\|endif\|command\|xcommand\|translate
      \\|xtranslate\|pragma\|error\|warning\)\>"
      \ skip=";\s*$" end="$"
      \ contains=xtplComment,xtplCommentBlock,xtplString,xtplNumber,xtplMarker,xtplTranslate
syn match xtplMarker "<[^<> \t]\+>" contained
syn match xtplTranslate "=>" contained

" ---- strings, numbers, constants ---------------------------------------------
syn region xtplString start=+"+ end=+"\|$+ contains=xtplInterp,@Spell
syn region xtplString start=+'+ end=+'\|$+ contains=xtplInterp,@Spell
syn region xtplInterp matchgroup=xtplInterpDelim start=+\${+ end=+}+ contained oneline
      \ contains=@xtplExpr,xtplInterpBraces
syn region xtplInterpBraces start=+{+ end=+}+ contained oneline transparent
      \ contains=@xtplExpr,xtplInterpBraces

" 12'345'678, 1.5, .5 -- not the 5 of 'a.5', but the 10 of '1..10'.
syn match xtplNumber "\%(\w\|\%(^\|[^.]\)\.\)\@<!\d\+\%('\d\+\)*\%(\.\d\+\%('\d\+\)*\)\=\%(\w\|'\)\@!"
syn match xtplNumber "\%(\w\|\.\)\@<!\.\d\+\%('\d\+\)*\%(\w\|'\)\@!"

syn match xtplBoolean "\.[tfyn]\."
syn keyword xtplNil nil
syn keyword xtplSelf self super
syn match xtplSelf "::"

" ---- statements --------------------------------------------------------------
syn keyword xtplConditional if elseif else endif case otherwise endcase
syn keyword xtplRepeat while enddo for to step next times
syn keyword xtplStatement exit loop return exec do default transaction
syn keyword xtplException begin sequence recover break try catch finally endtry
syn match xtplStatement "\<using\>"
syn match xtplStatement "\<using\s\+alias\>" nextgroup=xtplAliasName skipwhite
syn match xtplAliasName "\h\w*" contained nextgroup=xtplOrder skipwhite
syn match xtplOrder "\<order\>" contained
syn match xtplStatement "\<with\s\+object\>"
syn match xtplStatement "^\s*\zs\%(defer\|raw\)\>"
syn match xtplStatement "\<end\>\%(\s\+\%(using\|with\|raw\|sequence\|transaction\|case\|do\|if\)\>\)\="

" ---- declarations ------------------------------------------------------------
syn keyword xtplStorage local static private public protected constructor
syn match xtplStorage "\<external\>\%(\s\+alias\>\)\="
syn match xtplStorage "\<\%(user\|main\|template\)\>\ze\s\+\%(function\|procedure\)\>"
syn match xtplAttribute "<\s*\%(const\|contained\)\s*>"

syn keyword xtplDefine function procedure method wsmethod nextgroup=xtplFuncName skipwhite
syn match xtplFuncName "\h\w*" contained

syn keyword xtplStructure class interface wsrestful wsservice wsstruct from inherit
      \ nextgroup=xtplClassName skipwhite
syn match xtplClassName "\h\w*\%(\.\h\w*\)*" contained
syn keyword xtplStructure endclass endinterface endtype
syn match xtplStructure "\<end\s\+\%(class\|interface\|wsrestful\|wsservice\|wsstruct\|type\)\>"
syn keyword xtplStructure data wsdata nextgroup=xtplMemberName skipwhite
" 'type Item' alone on its line -- not 'Type("cX")'.
syn match xtplStructure "^\s*\zstype\ze\s\+\h\w*\s*\%($\|//\|&&\|/\*\)" nextgroup=xtplClassName skipwhite
syn match xtplMemberName "\h\w*" contained

syn keyword xtplNamespace namespace nextgroup=xtplNamespaceName skipwhite
syn match xtplNamespace "\<using\s\+namespace\>" nextgroup=xtplNamespaceName skipwhite
syn match xtplNamespaceName "\h\w*\%(\.\h\w*\)*" contained

syn match xtplAnnotation "^\s*\zs@\h\w*\%(\.\h\w*\)*"

" ---- types -------------------------------------------------------------------
" 'as Numeric', 'as Order'; 'Array<n>', 'Hash<c, Array<fixed n>>', 'Set<c>',
" 'Bag<c>'; a literal's '{ <n> }', '{ <c> => <Array<d>> }'.
syn keyword xtplAs as nextgroup=xtplType,xtplGeneric skipwhite
syn match xtplType "\h\w*" contained
syn region xtplGeneric matchgroup=xtplType start="\<\%(array\|hash\|set\|bag\)\s*<" end=">" oneline
      \ contains=xtplGeneric,xtplFixed,xtplTypeLetter
syn region xtplTypeArgs matchgroup=xtplDelimiter
      \ start="\%(\%({\|=>\)\s*\)\@<=<\ze\s*\%(\%(array\|hash\|set\|bag\)\s*<\|[nclahdobjf]\s*[>,]\)"
      \ end=">" oneline contains=xtplGeneric,xtplTypeLetter
syn keyword xtplFixed fixed contained
syn match xtplTypeLetter "\<[nclahdobjf]\>" contained

" ---- operators ---------------------------------------------------------------
syn match xtplOperator "(\%(|\|&\|-\|\^\|+\|\.\|<=\|<\|>=\|>\|==\|elem\|cont\))"
syn match xtplOperator "\.\%(and\|or\|not\)\."
syn match xtplOperator ":=\|+=\|-=\|\*=\|/=\|%=\|\^=\|?=\|?:\|=>\|%%\|++\|--\|\.\."
syn match xtplOperator "?\."
syn match xtplOperator "->"
syn keyword xtplOperator in has fallback
syn match xtplPipe "|>" nextgroup=xtplStage skipwhite
syn keyword xtplPipe then nextgroup=xtplStage skipwhite
syn match xtplStage "\h\w*" contained

" ---- calls, lambdas, blocks, aliases -----------------------------------------
syn match xtplVerb "\<\%(rows\|lines\)\ze\s*("
syn match xtplVerb "\<\%(map\|filter\|reject\|reduce\|fold\|take\|drop\|distinct\|sort\)\ze\s*("
syn match xtplVerb "\<\%(sortby\|reverse\|flatten\|enumerate\|chunks\|zip\|asum\|aprod\)\ze\s*("
syn match xtplVerb "\<\%(amax\|amin\|anyof\|allof\|noneof\|keys\|values\|pairs\|takewhile\)\ze\s*("
syn match xtplVerb "\<\%(dropwhile\|chunkby\|first\|count\|distinctadjacent\|maxby\|minby\)\ze\s*("
syn match xtplVerb "\<\%(scan\|expand\|tap\|pairwise\|queue\|split\|join\|starts\|ends\)\ze\s*("
syn match xtplVerb "\<\%(contains\|apick\|aroll\|setmaxroll\|setof\|bagof\|union\)\ze\s*("
syn match xtplVerb "\<\%(intersect\|minus\|symdiff\|bagsum\|bagprod\|subset\|psubset\)\ze\s*("
syn match xtplVerb "\<\%(superset\|psuperset\|sameset\|elems\|totalof\|kxxv\|minpairs\)\ze\s*("
syn match xtplVerb "\<\%(maxpairs\|heap\|heapof\)\ze\s*("

" '{|x, y| ...}': its parameters; '[o] o:nValue > 0': a lambda's, where a
" value starts -- after a value, '[' is an index.
syn match xtplBlockParams "\%({\s*\)\@<=|[^|]*|" contains=xtplParam
syn match xtplLambdaParams "\%(\w\|[)\]}]\)\@<!\[\s*\h\w*\%(\s*,\s*\h\w*\)\{,5}\s*\]\ze\s\+[^ \t:=]"
      \ contains=xtplParam
syn match xtplParam "\h\w*" contained

" 'aIt.nQtd', 'aIt.Total()', '.nQtd' in a type's method: a type's field
" and method -- not '.And.', '.T.', '1.5', '1..10'.
syn match xtplField "\%([.[:digit:]]\)\@<!\.\%(\%(and\|or\|not\|[tfyn]\)\.\)\@!\zs\h\w*"
syn match xtplFieldCall "\%([.[:digit:]]\)\@<!\.\%(\%(and\|or\|not\|[tfyn]\)\.\)\@!\zs\h\w*\ze\s*("

" 'SA1->A1_COD': the alias.
syn match xtplAliasName "\<\h\w*\ze\s*->"

" What an interpolation holds.
syn cluster xtplExpr contains=xtplString,xtplNumber,xtplBoolean,xtplNil,xtplSelf,xtplOperator,xtplPipe,xtplVerb,
      \xtplLambdaParams,xtplBlockParams,xtplAliasName,xtplConditional,xtplTypeArgs,xtplGeneric,xtplField,xtplFieldCall

syn sync ccomment xtplCommentBlock minlines=40

" ---- colors ------------------------------------------------------------------
hi def link xtplTodo          Todo
hi def link xtplComment       Comment
hi def link xtplCommentBlock  Comment
hi def link xtplInclude       Include
hi def link xtplIncludeFile   String
hi def link xtplPreProc       PreProc
hi def link xtplMarker        Identifier
hi def link xtplTranslate     PreProc
hi def link xtplString        String
hi def link xtplInterpDelim   Special
hi def link xtplNumber        Number
hi def link xtplBoolean       Boolean
hi def link xtplNil           Constant
hi def link xtplSelf          Special
hi def link xtplConditional   Conditional
hi def link xtplRepeat        Repeat
hi def link xtplStatement     Statement
hi def link xtplException     Exception
hi def link xtplOrder         Statement
hi def link xtplAliasName     Identifier
hi def link xtplStorage       StorageClass
hi def link xtplAttribute     StorageClass
hi def link xtplDefine        Keyword
hi def link xtplFuncName      Function
hi def link xtplStructure     Structure
hi def link xtplClassName     Type
hi def link xtplMemberName    Identifier
hi def link xtplField         Identifier
hi def link xtplFieldCall     Function
hi def link xtplNamespace     Keyword
hi def link xtplNamespaceName Identifier
hi def link xtplAnnotation    PreProc
hi def link xtplAs            Keyword
hi def link xtplType          Type
hi def link xtplFixed         StorageClass
hi def link xtplTypeLetter    Type
hi def link xtplDelimiter     Delimiter
hi def link xtplOperator      Operator
hi def link xtplPipe          Operator
hi def link xtplStage         Function
hi def link xtplVerb          Function
hi def link xtplBlockParams   Delimiter
hi def link xtplLambdaParams  Delimiter
hi def link xtplParam         Identifier

let b:current_syntax = "xtpl"

let &cpo = s:cpo_save
unlet s:cpo_save
