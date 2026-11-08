// xcb.ch -- the tree of the compiler written in xtpl (selfhost/), as the
// C++ xc's ast.h has it: a node is an array, its kind first, and each field
// at the position named here. selfhost/ast.xtpl makes them, with the C++
// defaults; selfhost/dump.xtpl writes them as xc-ast does.
#ifndef XCB_CH
#define XCB_CH

// ---- every node -------------------------------------------------------------
// Its kind, a number of its own -- what the compiler keeps per node, by it
// --, its line and its span in the source, in bytes from 0 (-1: none).
#define N_KIND        1
#define N_ID          2
#define N_LINE        3
#define N_FROM        4
#define N_TO          5
// A statement's: written on one line ('exec'), and bare.
#define S_ONELINE     6
#define S_BARE        7

// ---- expressions ------------------------------------------------------------
#define EK_LITERAL     1
#define EK_NAME        2
#define EK_USERTRANS   3
#define EK_CALL        4
#define EK_BINARY      5
#define EK_INDEX       6
#define EK_SELFREF     7
#define EK_SUBJECTREF  8
#define EK_MEMBER      9
#define EK_SAFEMEMBER  10
#define EK_HASHINDEX   11
#define EK_INTERVAL    12
#define EK_METHODCALL  13
#define EK_SAFECALL    14
#define EK_ALIASFIELD  15
#define EK_INALIAS     16
#define EK_MACRO       17
#define EK_REF         18
#define EK_OMITTED     19
#define EK_EXPRLIST    20
#define EK_ASSIGNEXPR  21
#define EK_ARRAYLIT    22
#define EK_INTERP      23
#define EK_JSONLIT     24
#define EK_HASHLIT     25
#define EK_CODEBLOCK   26
#define EK_LAMBDA      27
#define EK_GUARD       28
#define EK_PIPELINE    29
#define EK_DOT         30
#define EK_DOTCALL     31
#define EK_NAMED       32

// A literal's, and every literal kind's: its type's name, its text.
#define LIT_TYPE       6
#define LIT_TEXT       7
#define NAME_NAME      6
#define UT_TEXT        6
#define UT_BASE        7
#define CALL_NAME      6
#define CALL_ARGS      7
// Also the unary forms, '!' and 'neg', with no left.
#define BIN_OP         6
#define BIN_LEFT       7
#define BIN_RIGHT      8
#define IDX_BASE       6
#define IDX_INDICES    7
// Member, SafeMember -- 'x?.f' of a type's value: of that type, the field
// at its position (typed.xtpl).
#define MEM_BASE       6
#define MEM_NAME       7
#define MEM_TYPE       8
#define MEM_POS        9
#define HIX_BASE       6
#define HIX_KEY        7
#define HIX_SETKIND    8
#define IVL_LO         6
#define IVL_HI         7
// MethodCall, SafeCall -- 'x?.m()' of a type's value: of that type.
#define MC_BASE        6
#define MC_NAME        7
#define MC_ARGS        8
#define MC_TYPE        9
#define AF_BASE        6
#define AF_ALIAS       7
#define AF_FIELD       8
#define AF_MACRO       9
#define IA_BASE        6
#define IA_ALIAS       7
#define IA_EXPR        8
#define MAC_TARGET     6
#define MAC_CALLED     7
#define MAC_ARGS       8
#define REF_TARGET     6
#define EL_ITEMS       6
#define AE_TARGET      6
#define AE_OP          7
#define AE_VALUE       8
#define AE_INCDEC      9
#define ARR_ITEMS      8
#define ARR_ELEM       9
// An Interp's parts: a string, or an expression.
#define INTERP_PARTS   8
#define JSON_PAIRS     8
#define HASH_PAIRS     8
#define HASH_KEYTYPE   9
#define HASH_VALTYPE   10
#define HASH_SETKIND   11
// CodeBlock, Lambda.
#define CB_PARAMS      8
#define CB_BODY        9
#define GRD_EXPR       6
#define GRD_FALLBACK   7
#define PIPE_SOURCE    6
#define PIPE_STAGES    7
#define PIPE_THEN      8
// A type's field, 'x.f', and method, 'x.m()': of the type typed.xtpl knows
// the base to be of ('' while it does not), the field at its position.
#define DOT_BASE       6
#define DOT_NAME       7
#define DOT_TYPE       8
#define DOT_POS        9
#define DC_BASE        6
#define DC_NAME        7
#define DC_ARGS        8
#define DC_TYPE        9
// A field given by its name where a type's value is made: 'Item(n => 2)'.
#define NMD_NAME       6
#define NMD_VALUE      7

// ---- statements -------------------------------------------------------------
#define SK_DECLARATION      101
#define SK_ASSIGNMENT       102
#define SK_CALLSTMT         103
#define SK_RETURNSTMT       104
#define SK_EXITSTMT         105
#define SK_LOOPSTMT         106
#define SK_ANNOTATION       107
#define SK_IFSTMT           108
#define SK_CASESTMT         109
#define SK_WHILESTMT        110
#define SK_FORSTMT          111
#define SK_FORINSTMT        112
#define SK_FORTIMESSTMT     113
#define SK_MODIFIED         114
#define SK_DEFERRED         115
#define SK_USINGALIAS       116
#define SK_WITHOBJECT       117
#define SK_RAWSTMT          118
#define SK_TRYSTMT          119
#define SK_TRANSACTIONSTMT  120
#define SK_NOOPSTMT         121
#define SK_BREAKSTMT        122
#define SK_DEFAULTSTMT      123
#define SK_SEQUENCESTMT     124

#define DECL_SCOPE        8
#define DECL_DECLARATORS  9
#define ASG_TARGET        8
#define ASG_OP            9
#define ASG_VALUE         10
#define CS_CALL           8
#define RET_VALUE         8
#define ANN_NAME          8
#define ANN_ARGS          9
#define IF_BRANCHES       8
#define IF_OTHERWISE      9
#define IF_HEADER         10
#define CASE_BRANCHES     8
#define CASE_OTHERWISE    9
#define CASE_SUBJDECL     10
#define CASE_SUBJASSIGN   11
#define WH_COND           8
#define WH_BODY           9
#define WH_HEADER         10
#define FOR_VAR           8
#define FOR_VARLOCAL      9
#define FOR_FROM          10
#define FOR_TO            11
#define FOR_STEP          12
#define FOR_BODY          13
#define FOR_ENDFROM       14
#define FOR_ENDTO         15
#define FIN_ELEM          8
#define FIN_INDEX         9
#define FIN_KEYED         10
#define FIN_SOURCE        11
#define FIN_BODY          12
#define FIN_ENDFROM       13
#define FIN_ENDTO         14
#define FT_COUNT          8
#define FT_BODY           9
#define MOD_STMT          8
#define MOD_OP            9
#define MOD_COND          10
#define DEF_STMT          8
#define UA_AREA           8
#define UA_ORDER          9
#define UA_BODY           10
#define WO_SUBJECT        8
#define WO_BODY           9
#define RAW_BLOCK         8
#define RAW_LINES         9
#define TRY_BODY          8
#define TRY_ERRVAR        9
#define TRY_HANDLER       10
#define TRY_FINALLY       11
#define TX_BODY           8
#define NOOP_WORD         8
#define BRK_VALUE         8
#define BRK_EMPTYCALL     9
#define DFL_PAIRS         8
#define SEQ_BODY          8
#define SEQ_HASRECOVER    9
#define SEQ_ERRVAR        10
#define SEQ_RECLINE       11
#define SEQ_RECOVER       12

// ---- the rest of the tree ---------------------------------------------------
#define NK_KEYVALUE     201
#define NK_BRANCH       202
#define NK_DECLARATOR   203
#define NK_PARAM        204
#define NK_FUNCTIONDEF  205
#define NK_DATAMEMBER   206
#define NK_METHODSIG    207
#define NK_CLASSDEF     208
#define NK_METHODIMPL   209
#define NK_EXTERNAL     210
#define NK_PROGRAM      211
#define NK_TYPEFIELD    212
#define NK_TYPEDEF      213

#define KV_KEY            6
#define KV_VALUE          7
#define BR_COND           6
#define BR_BODY           7
// A Declarator's line is N_LINE.
#define DCL_NAME          6
#define DCL_INIT          7
#define DCL_DECLARED      8
#define DCL_ATTRS         9
#define DCL_TYPEFIRST     10
#define DCL_TYPESPEC      11
#define DCL_DIMS          12
#define DCL_CONTAINER     13
#define DCL_INITMADE      14
#define DCL_ASCLASS       15
#define PRM_NAME          6
#define PRM_DECLARED      7
#define PRM_TYPEWORD      8
#define PRM_ATTRS         9
#define PRM_ATTRSFROM     10
#define PRM_ATTRSTO       11
#define PRM_CONTAINER     12
#define PRM_TYPEFROM      13
#define PRM_TYPETO        14
#define PRM_TYPETLPP      15
// FunctionDef, DataMember, MethodSig, ClassDef, MethodImpl: their line is
// N_LINE; an External's line and span are N_LINE, N_FROM, N_TO.
#define FN_TYPE           6
#define FN_NAME           7
#define FN_PARAMS         8
#define FN_ANNOTATIONS    9
#define FN_BODY           10
#define FN_RETWORD        11
#define FN_RETCONTAINER   12
#define FN_RETFROM        13
#define FN_RETTO          14
#define FN_RETTLPP        15
// A type's method: its type, its own name -- the function is TYPE_METHOD,
// its first parameter 'Self' --, where 'method NAME' is, and its '('.
#define FN_OFTYPE         16
#define FN_METHOD         17
#define FN_HEADFROM       18
#define FN_HEADTO         19
#define FN_PAREN          20
#define DM_NAME           6
#define DM_TYPE           7
#define DM_VISIBILITY     8
#define DM_INIT           9
#define DM_INITWORD       10
#define DM_CONTAINER      11
#define DM_TYPEFROM       12
#define DM_TYPETO         13
#define DM_TYPETLPP       14
#define MS_NAME           6
#define MS_PARAMS         7
#define MS_VISIBILITY     8
#define MS_CONSTRUCTOR    9
#define MS_STATIC         10
#define MS_RETURNS        11
#define MS_RETCONTAINER   12
#define MS_RETFROM        13
#define MS_RETTO          14
#define MS_RETTLPP        15
#define CD_NAME           6
#define CD_SUPERS         7
#define CD_IFACES         8
#define CD_MEMBERS        9
#define CD_METHODS        10
#define CD_IFACE          11
#define MI_CLASS          6
#define MI_NAME           7
#define MI_PARAMS         8
#define MI_RETURNS        9
#define MI_BODY           10
#define MI_WS             11
#define MI_RETCONTAINER   12
#define MI_RETFROM        13
#define MI_RETTO          14
#define MI_RETTLPP        15
#define EXT_ALIAS         6
#define EXT_NAMES         7
#define PG_NS             6
#define PG_USINGS         7
#define PG_DIRECTIVES     8
#define PG_ANNOTATIONS    9
#define PG_FUNCTIONS      10
#define PG_CLASSES        11
#define PG_METHODS        12
#define PG_EXTERNALS      13
#define PG_STATICS        14
#define PG_TYPES          15
// A type's field: its declarator, the line's code at N_FROM, N_TO. A type:
// its line N_LINE, where it starts N_FROM; where its first line's code
// ends, where its last line starts and ends, that line; its fields, its
// methods (also among the program's functions).
#define TF_DECL           6
#define TD_NAME           6
#define TD_HEADTO         7
#define TD_ENDFROM        8
#define TD_ENDTO          9
#define TD_ENDLINE        10
#define TD_FIELDS         11
#define TD_METHODS        12
#define TD_BASE           13    // 'type B from A': A, whose fields and methods B has first
#define TD_HEADER         14    // the header it is from, 'item.xth', in a file that includes
                                // one; '' for the file's own

// ---- what the passes give ---------------------------------------------------
// A chain's stages, split (chains.xtpl): those that fuse, the terminal or
// Nil, the rest.
#define SP_FUSED          1
#define SP_TERMINAL       2
#define SP_REST           3
// The values of a function that go into a Decimal, and into a number
// (decimal.xtpl): hashes of their nodes' numbers.
#define DV_DECIMAL        1
#define DV_NUMERIC        2

#endif
