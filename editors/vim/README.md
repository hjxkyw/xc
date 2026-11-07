# xtpl for Vim

xtpl -- TL++ with xtpl's extensions, the language
[xc](https://github.com/hjxkyw/xc) compiles -- in Vim and Neovim:

- **Highlighting** of `.xtpl` files, as `editors/vscode` has it: TL++'s
  keywords, declarations and types; xtpl's own -- `|>` (and `then`, its
  word) and the runtime's verbs, lambdas (`[x] x * 2`), `defer`, `using
  alias`, `with object`, `fallback`, `?=`, `?:`, `?.`, `in`, `has`, `%%`,
  ranges, `${...}` inside strings, typed and fixed arrays and hashes
  (`Array<n>`, `Array<fixed n>`, `{ <c> => <n> }`), sets and bags
  (`Set<c>`, `Bag<c>`, `(|)`, `(elem)`), types and their fields (`type
  Item`, `aIt.nQtd`); Clipper's `&&` and `*` comments;
  the preprocessor's directives. A string ends at its quote or at the end
  of its line, as TL++'s: only a block comment, or a directive carried on
  with `;`, goes past a line -- so the colors are the same wherever the
  file is first shown from.
- `.xtpl` files read and written as windows-1252, as Protheus' sources
  are and as xc reads them.
- `//` comments for `gq` and the like, and two blanks a level, no tabs.

`syntax/xtpl.vim` colors, `ftdetect/xtpl.vim` says what an xtpl file is,
`ftplugin/xtpl.vim` sets the rest.

## Installing

As a package of Vim's (8 and later), linked from this folder into Vim's
own -- `~/.config/vim` when Vim keeps its files there (9.1 does, when
there is no `~/.vimrc` and no `~/.vim`: `:echo $MYVIMRC` says which),
else `~/.vim`:

```sh
mkdir -p ~/.config/vim/pack/xtpl/start
ln -s "$PWD" ~/.config/vim/pack/xtpl/start/xtpl                 # Vim, ~/.config/vim
mkdir -p ~/.vim/pack/xtpl/start
ln -s "$PWD" ~/.vim/pack/xtpl/start/xtpl                        # Vim, ~/.vim
mkdir -p ~/.local/share/nvim/site/pack/xtpl/start
ln -s "$PWD" ~/.local/share/nvim/site/pack/xtpl/start/xtpl      # Neovim
```

```bat
mkdir "%USERPROFILE%\vimfiles\pack\xtpl\start"
mklink /D "%USERPROFILE%\vimfiles\pack\xtpl\start\xtpl" "%CD%"
```

or, in the vimrc (`~/.config/vim/vimrc`, `~/.vimrc`), before `filetype
plugin on` and `syntax on`:

```vim
set runtimepath^=~/git/xc/editors/vim
```

A rule of one's own that makes `.xtpl` something else -- `autocmd BufRead
*.xtpl set filetype=...` in the vimrc, a file in `ftdetect/` of Vim's own
folder -- has to go: `:verbose set filetype?` in an `.xtpl` says `xtpl`,
and where it was set.

## Testing

```sh
vim -Nu NONE -i NONE -n -es --cmd "let g:out = '/dev/stdout'" -S editors/vim/test/syntax.vim
```

from the repository's root: each piece of xtpl in `test/syntax.vim` has to
come out in the group given, and no `.xtpl` of the repository may be left
inside a block comment or a directive at its end. ctest runs it as `vim`,
when CMake finds a `vim`.
