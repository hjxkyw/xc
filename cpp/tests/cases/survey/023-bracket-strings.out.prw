#include "totvs.ch"

#include "protheus.ch"

// Clipper's '[...]' strings, which a .prw takes (a .tlpp does not: C2003,
// tried on 24.3.1.9) -- where what follows the ']' starts no value; before
// one, '[x] x > 0' is still a lambda.
User Function Brackets(aX)
  Local cX := [abc]
  Local aPos := u_xtpl_filter(aX, {|x| x > 0})
  Local lIn := "VVA" $ [VVA/VVB] .And. [abc] + "d" == "abcd"
  ASort(aX, , , {|x, y| x < [y]})
Return lIn .And. "b" $ cX .And. Len(aPos) > 0
