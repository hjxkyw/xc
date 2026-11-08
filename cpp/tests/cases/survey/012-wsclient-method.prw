#include "protheus.ch"
#include "apwebsrv.ch"

// A web service's client, as ADVPL WSDL Client writes it: its methods say
// WSCLIENT, not WSSERVICE, and xc stopped on them
// (danielAlbuquerque/advpl_webservice, CliWsServerTime.prw).
WSCLIENT WSXSERVERTIME
  WSMETHOD NEW
  WSMETHOD MOSTRAHORA
  WSDATA   _URL         AS String
  WSDATA   cPARAMETRO   AS string
ENDWSCLIENT

WSMETHOD NEW WSCLIENT WSXSERVERTIME
::Init()
Return Self

WSMETHOD MOSTRAHORA WSSEND cPARAMETRO WSRECEIVE cMOSTRAHORARESULT WSCLIENT WSXSERVERTIME
Local cSoap := ""
cSoap += "<MOSTRAHORA/>"
Return .T.
