" xtpl -- TL++ with xtpl's extensions (editors/vim): a .xtpl file is xtpl,
" and so is a .xth, a header of types; read and written as windows-1252, as
" Protheus' sources are and as xc reads them -- what Vim's own
" 'fileencodings' would take for latin1 or UTF-8.
autocmd BufNewFile,BufRead *.xtpl,*.xth setfiletype xtpl
autocmd BufNewFile *.xtpl,*.xth setlocal fileencoding=cp1252
autocmd BufReadPre *.xtpl,*.xth let s:fencs = &fileencodings | set fileencodings=cp1252
autocmd BufReadPost,FileReadPost *.xtpl,*.xth if exists('s:fencs') | let &fileencodings = s:fencs | unlet s:fencs | endif
