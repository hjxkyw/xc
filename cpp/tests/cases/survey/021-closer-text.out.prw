#include "protheus.ch"

// What follows a closing word on its line the AppServer takes for nothing
// ('EndIf lOk', 'EndDo nN < 3', tried on 24.3.1.9); 'EndIf', 'EndDo' and
// 'EndCase' cut to four letters or more, as Clipper's ('Endi' in TOTVS' own
// ATFR200.PRX).
User Function Text(lOk)
  Local nN := 0
  If lOk
    nN++
  EndIf lOk
  While nN < 3
    nN++
  EndDo nN < 3
  If nN == 3
    nN++
  Endi
  While nN < 6
    nN++
  Endd
  Do Case
  Case nN == 6
    nN++
  Endcas  // the case
Return nN
