// xc -- typed arrays and hashes: what goes into one.
//
// 'Local aN := { <n> }', 'Local aN as Array<n>', 'Local hH := { <c> => <n> }',
// 'Local hH as Hash<c, n>' -- and nested, 'Array<Array<n>>' -- say what an
// array or a hash holds; a function's parameters and what it returns may say
// it too. TL++ is given none of it (lower.cpp writes 'as Array', 'as
// Object', '{}'): it is xc's to check, here, as the file is compiled.
//
// What goes into one is checked against what it holds: a declaration's
// value, 'x := v', 'a[i] := v', 'h{k} := v', AAdd(), AFill(), ACopy(),
// h:Set(), an argument a parameter so declared takes, a return in a function
// so declared. A value known to be of another type is an error; one whose
// type xc cannot tell, a warning.
//
// A fixed one -- 'Array<fixed>', 'Array<fixed n>', 'Hash<fixed c, n>' -- is
// written into by nothing: no 'a[i] := v', no AAdd(), ASort() and the other
// functions that change an array, no h:Set() or h:Del(); nor is anything it
// holds. Its name takes its value where it is declared, and is never assigned
// again nor passed with '@'. A fixed one goes only where a fixed one is
// wanted, or where nothing is said: a name it is given is fixed too.
//
// A set, 'Set<k>', is a hash of Logicals, a bag, 'Bag<k>', one of counts
// (Raku's): setOf(), bagOf() and the set operators make them, and they go
// where such a hash is wanted. Each 'h{k}' xc knows to be a set's or a bag's
// is marked so (HashIndex::set_kind), for the back ends to read and write it
// Raku's way.
//
// What xc can tell: literals; a name declared with a type, and a function's
// Local or Static whose every assignment xc can tell, and the same; what
// reading a typed array or hash gives; an operator's result; TL++'s common
// functions, the runtime's verbs over a typed array, and the file's own
// functions declared with a type; a field, given the dictionary. Not a
// method, a parameter declared with no type, a Private, a macro, a field
// without the dictionary.

#pragma once

#include <vector>

#include "ast.h"
#include "check.h"

namespace xc
{
  // The errors and warnings: nothing, for a file with no typed array or hash.
  Checked typed_problems(const Program* p, const Dictionary& dictionary);
}
