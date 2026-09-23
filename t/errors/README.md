# xtpl's errors

Copied from xtpl's `errors/` (version 116). xtpl is deprecated and now only
serves to bootstrap xc. Each `.xtpl` is a source xtpl refuses, and the `.err`
next to it is the message xtpl gives.

`t/17-xtpl-errors.raku` reads them and sorts them into four groups:

- **syntax** -- the grammar has to refuse it. Each one also has a correction,
  a minimal text replacement in the test itself, and the corrected source has
  to parse: that is what shows the refusal came from the right error and not
  from something else in the file.
- **analysis** -- the error is about names, scope, types or calls. The grammar
  has to accept it; refusing it is the job of an analysis pass that does not
  exist yet.
- **decided** -- xc accepts it on purpose, against xtpl.
- **pending** -- it uses a construct xc cannot read yet. It is shown in the
  output, but not counted.

A file in none of the groups makes the test fail.

The messages in the `.err` files are xtpl's; xc gives no messages yet, so for
now they are here for reference.
