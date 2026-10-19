# xtpl's errors

Copied from xtpl's `errors/` (version 116). xtpl is deprecated and now only
serves to bootstrap xc. Each `.xtpl` is a source xtpl refuses, and the `.err`
next to it is the message xtpl gives.

The Raku xc's `t/17-xtpl-errors.raku` (in
[hjxkyw/xc-raku](https://github.com/hjxkyw/xc-raku)) read them, and sorted
them into four groups: **syntax**, which the grammar has to refuse -- each
with a correction, a minimal replacement in the test, after which the source
has to parse, so the refusal is known to come from the right error;
**analysis**, about names, scope, types or calls, which the grammar takes
and the checks refuse; **decided**, which xc takes on purpose, against
xtpl; and **pending**, a construct xc could not read yet. The programs that
test compiled are the cases in `cpp/tests/cases/17-xtpl-errors/`. Here
nothing reads them: they are kept for what they say about xtpl.

The messages in the `.err` files are xtpl's, not xc's.
