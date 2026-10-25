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
