" xtpl -- TL++ with xtpl's extensions (editors/vim): a .xtpl file is xtpl,
" read and written as windows-1252, as Protheus' sources are and as xc reads
" them -- what Vim's own 'fileencodings' would take for latin1 or UTF-8.
autocmd BufNewFile,BufRead *.xtpl setfiletype xtpl
autocmd BufNewFile *.xtpl setlocal fileencoding=cp1252
autocmd BufReadPre *.xtpl let s:fencs = &fileencodings | set fileencodings=cp1252
autocmd BufReadPost,FileReadPost *.xtpl if exists('s:fencs') | let &fileencodings = s:fencs | unlet s:fencs | endif
