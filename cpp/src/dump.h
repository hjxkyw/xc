// xc -- the tree as text, one field to a line (xc-ast).
//
// Every node by its kind's name, then each of its fields in the order ast.h
// declares them, indented two more: a number, true or false, a string in
// double quotes -- '\\', '\"' and every byte under 32 or over 126 as '\xHH'
// --, nil for a null pointer or an empty optional, a list of strings in
// brackets, a list of nodes as its count in parentheses with the nodes
// below. selfhost/dump.xtpl writes the same, for the parser written in xtpl
// to be held to this one.

#pragma once

#include <string>

#include "ast.h"

namespace xc
{
  std::string dump(const Program* p);

  // One expression, as dump() writes it -- 'nil' for none.
  std::string dump_expr(const Expr* e);
}
