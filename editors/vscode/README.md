# xtpl for Visual Studio Code

xtpl -- TL++ with xtpl's extensions, the language
[xc](https://github.com/hjxkyw/xc) compiles -- in the editor:

- **Highlighting** of `.xtpl` files: TL++'s keywords, declarations and
  types; xtpl's own -- `|>` (and `then`, its word) and the runtime's verbs,
  lambdas (`[x] x * 2`), `defer`, `using alias`, `with object`, `fallback`,
  `?=`, `?:`, `?.`, `in`, `has`, `%%`, ranges, `${...}` inside strings,
  hashes, typed and fixed arrays and hashes (`Array<n>`, `Array<fixed n>`,
  `{ <c> => <n> }`), sets and bags (`Set<c>`, `Bag<c>`, `(|)`, `(elem)`);
  Clipper's `&&` and `*` comments; the preprocessor's directives.
- **xc's checks** as diagnostics, each time a file is opened or saved:
  what would stop the compile is an error, a warning is a warning, on its
  line.
- **xtpl: Compile this file to TL++**, in the command palette: the `.tlpp`
  next to the source.
- `.xtpl` files open as windows-1252, as Protheus' sources are and as xc
  reads them.

## Installing

From a package, which `npx @vscode/vsce package` makes here:

```sh
code --install-extension xtpl-0.2.0.vsix
```

Or from this folder as it is, with no packaging -- a copy, or a link, in
VS Code's extensions folder:

```sh
ln -s "$PWD" ~/.vscode/extensions/hjxkyw.xtpl-0.2.0     # Linux
```

```bat
mklink /D "%USERPROFILE%\.vscode\extensions\hjxkyw.xtpl-0.2.0" "%CD%"   & rem Windows
```

and restart VS Code. The checks need xc itself, the C++ program: built
in a clone of xc (`cpp/build`; see xc's README), or named in `xtpl.xc.path`.

## Settings

| Setting | |
|---|---|
| `xtpl.xc.path` | where xc is, the program; empty: xc as CMake built it in a folder of the workspace (`cpp/build/xc`, `cpp\build\Release\xc.exe`), else `xc` on the PATH |
| `xtpl.xc.includes` | where the include files are, `a;b`, as xc's `--includes` |
| `xtpl.xc.dictionary` | an exported SX3, for xc's `--dict` |
| `xtpl.xc.checkOnSave` | check on open and on save (on by default) |

The checks run `xc --check file.xtpl` in the file's workspace folder, so a
relative path in the settings is from there; what xc printed is in the
**xc** output panel. 0.1.0 ran the Raku xc, `rakupp bin/xc`; its
`xtpl.xc.raku` setting is gone.

## Testing

```sh
npm install
npm test
```

`test/grammar.test.js` runs the grammar with the engine VS Code uses
(vscode-textmate): each piece of xtpl it lists has to come out with its
scope, and no `.xtpl` file of the repository may be left inside a string, a
comment or a bracket at its end. `test/xcoutput.test.js` reads xc's output as
diagnostics.
