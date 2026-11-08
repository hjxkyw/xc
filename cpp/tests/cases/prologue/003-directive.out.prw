#include "totvs.ch"

#include "protheus.ch"

// A directive ends no prologue: TOTVS' own sources declare a Local after
// an '#IFDEF TOP', and xc said it could not be declared there.
Static Function Detail()
  Local cDir := MsDocPath()
  #IFDEF TOP
    Local aStru := {}
  #ELSE
    Local cIndex := ""
  #ENDIF
  Local nX := 0
  nX++
Return cDir
