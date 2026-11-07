" Vim filetype plugin file
" Language: xtpl -- TL++ with xtpl's extensions (editors/vim)
"
" Comments as TL++ writes them, '//' and '/* */'; two blanks a level, no
" tabs, as xc's sources are and editors/vscode sets.

if exists("b:did_ftplugin")
  finish
endif
let b:did_ftplugin = 1

let s:cpo_save = &cpo
set cpo&vim

setlocal comments=s1:/*,mb:*,ex:*/,://,:&&
setlocal commentstring=//\ %s
setlocal formatoptions-=t formatoptions+=croql
setlocal shiftwidth=2 softtabstop=2 expandtab

let b:undo_ftplugin = "setlocal comments< commentstring< formatoptions< shiftwidth< softtabstop< expandtab<"

let &cpo = s:cpo_save
unlet s:cpo_save
