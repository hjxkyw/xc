#include "protheus.ch"

// Clipper's commands, as TOTVS' preprocessor takes them, are taken whole --
// 'STORE 0 TO nA, nB', 'REPLACE (cAlias)->F WITH x', 'USE' alone; and
// TOTVS' 'BEGIN REPORT QUERY', 'ADD LEGEND', 'NEW MODEL'. 'store := 1' is
// still an assignment.
User Function Clipper(cAlias, cFile, oReport, oBrowse, oServer)
  Local store := 0
  Local nA, nB
  STORE 0 TO nA, nB
  Store .F. To lA, lB
  Use (cFile) Alias (cAlias) New Exclusive
  USE &cFile ALIAS "DADOS" NEW
  Replace (cAlias)->F_COD With "1"
  Replace &(cFile) With 2
  Replace;
    F_NOME With "x"
  Seek xFilial("SA1") + "01"
  Go nA
  Goto Bottom
  Skip
  Skip -1
  Commit
  Zap
  Eject //-- the last page
  Delete File &(cFile)
  Dele File &(cFile + ".##R")
  Copy To &cFile
  COPY FILE &cFile TO &(cFile + ".bak")
  APPEND FROM &cFile SDF
  INDEX ON F_COD TO &cFile
  close TRB1
  Use
  BEGIN REPORT QUERY oReport:Section(1)
  END REPORT QUERY oReport:Section(1)
  ADD LEGEND DATA "C1_FLAG == '1'" COLOR "BROWN" TITLE "Done" OF oBrowse
  CREATE RPCCONN oServer ON SERVER "localhost" PORT 1234 ENVIRONMENT "zv" EMPRESA "99" FILIAL "01"
  CLOSE RPCCONN oServer
  store := 1
Return store
