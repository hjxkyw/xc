#include "totvs.ch"

#include "protheus.ch"

// A command goes on past a ';' with a comment after it, as the
// preprocessor has it (TOTVS' own reports, TECR530.PRX).
User Function Report(oSection1, nTotal)
  DEFINE CELL NAME "nTotal" OF oSection1 ALIAS " " TITLE "Tempo" PICTURE "@E 99.99" ;	//"Tempo de Atend."
    BLOCK {|| nTotal }
  @ 1, 0 PSAY "Total: " ;  // the label
    + Str(nTotal)
Return nil
