#include "protheus.ch"

// A procedure is a function, to xc, as AdvPL has it (siga0984/Blog,
// NaldoDj-zz/BlackTDN).
User Function Proc()
  Logged("start")
Return nil

Static Procedure Logged(cText)
  ConOut(cText)
Return
