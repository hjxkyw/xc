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
#include <vector>

#include "ast.h"

namespace xc
{
  // Whether a name is one of the runtime's verbs, which the output calls as
  // u_xtpl_<name>.
  bool is_runtime_verb(const std::string& name);

  // The verbs that take a block, where a bare function name is that
  // function: 'map(alltrim)'.
  bool takes_block(const std::string& lc_name);

  // A rows()/lines() call or a range 'lo..hi'.
  bool is_source(const Expr* e);

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
}
