#include "protheus.ch"

// 'as Char' and 'as Block' in a .prw, which takes them (tried on 24.3.1.9;
// 98 of TOTVS' own reports have them). TL++ refuses them.
User Function CharBlock()
  Local cX as Char
  Local bX as Block
  cX := "a"
  bX := {|| cX}
Return Eval(bX)
