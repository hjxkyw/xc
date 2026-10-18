#include "totvs.ch"

#include "protheus.ch"

// An AdvPL source (.prw) stays AdvPL: xc writes a .prw, without
// tlpp-core.th, and TL++'s own rules do not hold -- AdvPL's words for types
// ('As String'), a call with more arguments than the function takes (the
// rest are dropped: a warning), a Decimal given a number, a typed Local's
// starting value. xtpl's own forms are lowered as in a .xtpl.
Class Pessoa
  Data cNome As String
  Data lAtivo As Logic
  Method New() Constructor
EndClass

Method New() Class Pessoa
  ::cNome := "x"
  ::lAtivo := .T.
Return Self

User Function Adv(aItens)
  Local nX as Numeric
  Local nD := 5 as Decimal
  Local nA := If(ValType(nX) != "U", nX, 1)
  Local nSoma := u_xtpl_asum(u_xtpl_filter(aItens, {|x| x > 0}))
  conout(Dobro(nA, nD))
Return nSoma

Static Function Dobro(n)
Return n * 2
