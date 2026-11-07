// A type in AdvPL: the same arrays, #defines and static functions.
#include "totvs.ch"

// type Point: an array of 2
#define Point_nX 1
#define Point_nY 2

Static Function Point_Sum(aSelf as Array) as Numeric
Return aSelf[Point_nX] + aSelf[Point_nY]
// endtype

User Function Pontos()
  Local aP := {1, 2}
  aP[Point_nY] += 3
Return Point_Sum(aP)
