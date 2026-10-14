// xc -- a tree as JSON, as tools/ast-json.raku writes the Raku xc's: the two
// are compared as text.
//
// A node is an object: "node", its class, then each attribute in the order
// the Raku class declares them (its own, then its parents'). Null for what
// is missing. A string is its bytes: each byte below 0x20 or above 0x7E, '"'
// and '\' as \u00XX -- the byte, not a character of Unicode.

#pragma once

#include <string>

#include "ast.h"

namespace xc
{
  std::string to_json(const Expr* e);
  std::string to_json(const Program* p);
}
