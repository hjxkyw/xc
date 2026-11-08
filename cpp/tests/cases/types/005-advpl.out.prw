// A type in AdvPL: the same arrays, #defines and static functions.
#include "totvs.ch"

// type Point: an array of 2
#define Point_nX 1
#define Point_nY 2

Static Function Point_Sum(eSelf as Array) as Numeric
Return eSelf[Point_nX] + eSelf[Point_nY]
// endtype

User Function Pontos()
  Local eP := {1, 2}
  eP[Point_nY] += 3
Return Point_Sum(eP)
