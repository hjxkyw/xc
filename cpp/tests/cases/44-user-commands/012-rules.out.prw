#include "totvs.ch"

#include "protheus.ch"

// A rule's last line ending in ';;' -- a ';' of what it stands for, and the
// ';' that carries it on -- carries it on to the next line only, not past
// it into the next rule (NaldoDj-zz/BlackTDN's tryexception.ch). And an
// optional clause's marker does not take a word the pattern has after it:
// 'WITH WEBEXOBJECT CLASS X' gives <obj> nothing (DNATechByNaldoDJ/fw.webex).
#xcommand CATCHX => ;
    ConOut("caught") ;;
    RECOVER ;;

#xcommand CATCHX USING <o> => ;
    RECOVER ;;
    <o> := 1 ;;

#xcommand WITH WEBOBJ [<obj>] CLASS <class> => [<obj>:=] <class>():New()

User Function Catch()
  Local oE
  Local oPage
  BEGIN SEQUENCE
    ConOut("try")
  CATCHX USING oE
  END SEQUENCE
  WITH WEBOBJ oPage CLASS WebPage
  WITH WEBOBJ CLASS WebBody
Return oE
