#include "protheus.ch"

// '@' and a row that starts with a name or a call: TOTVS' commands, as
// '@ 10, 5' is -- '@li, 14 PSAY', '@Prow()+1,0 PSAY' (TOTVS' own reports,
// some 330 sources). '@oJSON := x' stays an assignment.
User Function Lines(li, nLin)
  Local oJSON
  @li, 14 PSAY "Total"
  @Prow()+1,0 PSAY "*** CANCELADO PELO OPERADOR ***"  //"cancelled"
  @nLin,00 PSAY Replicate("-", 80)
  @oJSON := JsonObject():New()
Return oJSON
