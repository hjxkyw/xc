// xc -- what the passes between the parser and the back end find in a tree,
// as text (xc-ast --facts): what selfhost/facts.xtpl writes, for walk.xtpl,
// chains.xtpl, decimal.xtpl and typed.xtpl to be held to the C++ ones.
//
// A unit to a function -- the file's statics first, then its functions, then
// its methods --, each statement of it in walk() order, and below it each
// expression exprs_of() and walk_expr() give, with what decimal.h and
// chains.h say of it. typed_problems() has been run: its marks are in the
// tree dump() writes before these.

#pragma once

#include <string>

#include "ast.h"

namespace xc
{
  std::string facts(const Program* p, bool advpl);
}
