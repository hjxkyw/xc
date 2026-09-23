# xc

A compiler from xtpl to TL++, written in Raku.

## Installing rakupp

```sh
curl -sfL -O https://github.com/ash/rakupp/releases/download/v4.0.1/rakupp-linux-x86_64.tar.gz
tar xzf rakupp-linux-x86_64.tar.gz
export PATH=$PWD/rakupp/bin:$PATH
```

## Running the tests

```sh
rakupp run-tests.raku
```

A single test runs on its own too:

```sh
rakupp t/08-tree.raku
```
