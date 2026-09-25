# xc

A compiler from xtpl to TL++, written in Raku.

## Installing rakupp

```sh
curl -sfL -O https://github.com/ash/rakupp/releases/download/v4.0.1/rakupp-linux-x86_64.tar.gz
tar xzf rakupp-linux-x86_64.tar.gz
export PATH=$PWD/rakupp/bin:$PATH
```

## Compiling a file

```sh
rakupp bin/xc file.xtpl              # writes file.tlpp
rakupp bin/xc file.xtpl out.tlpp
```

The generated code calls xtpl's runtime, `runtime/xtpl_runtime.tlpp`, which
has to be compiled into the RPO alongside it.

## Running the tests

```sh
rakupp run-tests.raku
```

A single test runs on its own too:

```sh
rakupp t/08-tree.raku
```
