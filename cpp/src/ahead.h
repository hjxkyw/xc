// xc -- looking ahead, cheaply: whether the rest of a statement is an
// assignment or a chain, before trying to read it as one.

#pragma once

#include <string_view>

namespace xc
{
  // What the rest of the line says -- the text from the cursor to the end of
  // the line, and the lines a ';' carries it on to. $what: 'assign' (an
  // assignment, '=' alone included), 'bind' (one with ':=' and the like, not
  // '='), 'pipe' (a '|>'). item: an argument or a lambda's body, which also
  // ends at a ',' or at a bracket closing what it is in.
  enum class Ahead { Assign, Bind, Pipe };

  bool ahead(std::string_view text, Ahead what, bool item);
}
