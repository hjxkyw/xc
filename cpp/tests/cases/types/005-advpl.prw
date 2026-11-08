// A type in AdvPL: the same arrays, #defines and static functions.
#include "totvs.ch"

type Point
  nX as Numeric
  nY as Numeric

  method Sum() as Numeric
  Return .nX + .nY
endtype

User Function Pontos()
  Local eP := Point(1, 2)
  eP.nY += 3
Return eP.Sum()
