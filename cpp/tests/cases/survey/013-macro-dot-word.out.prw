#include "protheus.ch"

// The '.' that ends a macro's name is right after it: '&cCond .And. x' is
// the macro and an '.And.' -- xc took the '.' for the macro's
// (jeanvga/relatorios-protheus-legado, a While of TOTVS' own).
User Function Cond(cCond, nX)
  Local lOk := .F.
  If &cCond .And. nX > 1
    lOk := .T.
  EndIf
  If &cCond .Or. &cCond.And. nX > 2
    lOk := .F.
  EndIf
  If &cCond. == "x"
    lOk := .T.
  EndIf
Return lOk
