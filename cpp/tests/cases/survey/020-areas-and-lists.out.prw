#include "totvs.ch"

#include "protheus.ch"

// An area's parentheses hold a list, an assignment first or not --
// '(cAlias)->(dbEval(b), dbCloseArea())', 'SRA->(cFil := RA_FILIAL, ...)';
// a macro names an area -- '&(cAlias)->(DbSetOrder(1))'; a list in
// parentheses is a statement; an array's item may be an assignment.
User Function Areas(cAlias, nCol)
  Local nQtd := 0
  Local cFil, cTno
  Local aCab
  (cAlias)->(dbEval({|| nQtd++ }), dbCloseArea())
  SRA->( cFil := RA_FILIAL , cTno := RA_TNOTRAB )
  &(cAlias)->(DbSetOrder(1))
  &cAlias->(DbGoTop())
  ( ConOut(cFil), ConOut(cTno) )
  aCab := {nCol += 10, "x", nQtd := 2}
Return aCab
