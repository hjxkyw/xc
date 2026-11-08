#include "protheus.ch"

// What follows an 'End' AdvPL takes for nothing: TOTVS' own sources close a
// While with 'End While', a Do Case with 'End Do', a For with 'EndFor' --
// and others a For with 'End', a While with 'End-While'.
User Function Closers(nN)
  Local nI
  While nN < 3
    nN++
  End While
  While nN < 6
    nN++
  End-While
  Do Case
  Case nN == 6
    nN++
  End Do
  For nI := 1 To 2
    nN++
  EndFor
  For nI := 1 To 2
    nN++
  End
Return nN
