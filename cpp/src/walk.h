// xc -- walking the tree (XC::AST's subexprs, walk-expr, bodies-of, walk).
//
// Missing parts -- the empty side of a '!', the base of an 'SA1->' -- do not
// appear. What is inside comes in reading order, as the Raku classes' 'kids'
// give it: the checks and the emitter say what they find in that order.

#pragma once

#include <functional>
#include <vector>

#include "ast.h"

namespace xc
{
  // The expressions right below e.
  std::vector<Expr*> subexprs(const Expr* e);

  // f on e and on every expression inside it, in reading order.
  void walk_expr(Expr* e, const std::function<void(Expr*)>& f);

  // The expressions a statement holds, without going into its bodies.
  std::vector<Expr*> exprs_of(const Stmt* s);

  // The bodies a statement holds, in reading order -- the statement a
  // modifier or a 'defer' holds a body of its own.
  std::vector<Body> bodies_of(const Stmt* s);

  // f on each statement of a body, and on the ones inside, in reading order.
  void walk(const Body& body, const std::function<void(Stmt*)>& f);
}
