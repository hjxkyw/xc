// xc -- chains: xtpl's verbs, the sources, and which stages fuse into a loop
// (XC::Emit's, shared with the checks: one decision, not two that could
// drift apart).
//
// rows() and lines() are sources, not functions: a chain from one becomes a
// loop over the work area or the file, with the stages inside it. A chain
// over an array fuses the same way when it is a statement's whole value and
// at least two of its stages fuse (all of them, for a chain run for its
// effects), or one that carries a block. A stage that cannot be part of a
// loop -- 'sortby', 'split' -- does not end the fusing: it is a call, and a
// loop starts again after it (fuse_from).

#pragma once

#include <functional>
#include <string>
#include <unordered_set>
#include <vector>

#include "ast.h"

namespace xc
{
  // Whether a name is one of the runtime's verbs, which the output calls as
  // u_xtpl_<name>.
  bool is_runtime_verb(const std::string& name);

  // A set operator's runtime function: '(|)' is 'u_xtpl_union'; '' for any
  // other operator.
  std::string set_function(const std::string& op);

  // A verb's call, its arguments written: setOf() and bagOf() of other than
  // one argument take them as one array -- 'setof(1, 2)' is
  // 'u_xtpl_setof({1, 2})'.
  std::string verb_call(const std::string& name, const std::vector<std::string>& args);
  bool one_array(const std::string& name, std::size_t args);

  // The runtime's read and write of a key: a hash's, or -- as typed.cpp knows
  // it -- a set's (.F. where it is not; .F. written takes it out) or a bag's
  // (0 where it is not; below 1 takes it out).
  std::string key_reader(const HashIndex* h);
  std::string key_writer(const HashIndex* h);

  // The verbs that take a block, where a bare function name is that
  // function: 'map(alltrim)'.
  bool takes_block(const std::string& lc_name);

  // A rows()/lines() call or a range 'lo..hi'.
  bool is_source(const Expr* e);

  // The source a chain starts from -- the head of a Pipeline that is one, or
  // a source alone --, or null; and its kind: 'rows', 'lines' or 'range'.
  const Expr* source_call(const Expr* e);
  std::string source_kind(const Expr* src);

  // Whether a name (in lower case) is a variable of the function: then
  // 'filter(bOk)' is a block held in it, not a function to call.
  using Declared = std::function<bool(const std::string&)>;

  // A chain's stages split into the fused run, the terminal that may end it,
  // and the rest, which apply to the result.
  struct Split
  {
    std::vector<Call*> fused;
    Call* terminal = nullptr;
    std::vector<Call*> rest;
  };

  // The split of stages, from wherever the walk starts: over an array
  // (array), or over a source.
  Split split_stages(const std::vector<Call*>& stages, bool array, const Declared& declared);

  // Where a chain over an array becomes a loop: the first of its stages from
  // which what is left fuses, or -1 when it fuses from none.
  int fuse_from(const std::vector<Call*>& stages, const Declared& declared, bool for_effect);

  // The names a function declares, in lower case, wherever in it: its
  // parameters, its declarations, the names its block headers and loops
  // declare. Not a lambda's parameters, not the file's statics.
  std::unordered_set<std::string> declared_names(const std::vector<Param*>& params, const Body& body);

  // Whether a step of one parameter uses it for anything but a field: over
  // rows(), before a map, the element is the current record.
  bool record_misused(const Lambda* l);

  // What keeps a chain that runs as a loop from being written as one -- in
  // xtpl's words, each a finding of its statement; for_effect: the chain is
  // a statement of its own.
  std::vector<std::string> chain_problems(const Expr* chain, bool for_effect, const Declared& declared);
}
