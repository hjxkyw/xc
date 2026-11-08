#include "totvs.ch"

#include "protheus.ch"

// A code block's item may be left out, as AdvPL takes it: '{|x|, x[1] ==
// 2}' in TOTVS' own reports, '{|| f(), }', '{|| ,,}'. Nothing is done for
// it; the last left out gives Nil. Its names may have blanks around them.
User Function Items(aSM0)
  Local nCount := 0
  Local nAt := AScan(aSM0, {|sm0|, sm0[1] == "01"})
  Local bTwice := {|| nCount++, nCount++, }
  Local bNone := {|| ,,}
  Local bSum := {| nA , nB | nA + nB }
  Local bMiddle := {|| nCount := 10, , nCount + 1}
  ConOut(nAt, Eval(bTwice), Eval(bNone), Eval(bSum, 1, 2), Eval(bMiddle), nCount)
Return nCount
