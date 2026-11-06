# The compiler written in xtpl (selfhost/), held to the C++ xc: xc compiles
# it to bytecode, xc-vm runs it -- after xtpl's runtime -- over each source
# of the folders given, and the tree it reads each into, marked, with what
# the passes after the parser find in it, must be what 'xc-ast --bare
# --facts' writes, byte for byte; and of each of those sources that 'xc
# --bytecode' compiles, the .xbc it writes must be xc's -- of one it does
# not compile only for what cannot become bytecode yet, what it says of
# that.
#
#   cmake -DXC=cpp/build/xc -DVM=cpp/build/xc-vm -DAST=cpp/build/xc-ast
#         -DROOT=. -DWORK=cpp/build/selfhost -P cpp/tests/selfhost.cmake
#
# CMake runs it as a test (ctest). DIRS (';'-separated, under ROOT) are the
# folders whose .xtpl and .prw are read; when none is given, selfhost/tests,
# cpp/tests/bytecode and each folder of cpp/tests/cases. A .val is read a
# line at a time, each in every form a statement holds an expression as --
# 'xc-ast --values'.

get_filename_component(ROOT "${ROOT}" ABSOLUTE)
if(NOT DIRS)
  set(DIRS selfhost/tests cpp/tests/bytecode)
  file(GLOB cases LIST_DIRECTORIES true RELATIVE ${ROOT} ${ROOT}/cpp/tests/cases/*)
  foreach(c ${cases})
    if(IS_DIRECTORY ${ROOT}/${c})
      list(APPEND DIRS ${c})
    endif()
  endforeach()
endif()
file(REMOVE_RECURSE ${WORK})
file(MAKE_DIRECTORY ${WORK}/expect ${WORK}/got)

# ---- the compiler, as bytecode -----------------------------------------------
set(modules "")
foreach(m ${ROOT}/runtime/xtpl_runtime.tlpp ${ROOT}/selfhost/ast.xtpl ${ROOT}/selfhost/dump.xtpl
          ${ROOT}/selfhost/parse.xtpl ${ROOT}/selfhost/walk.xtpl ${ROOT}/selfhost/chains.xtpl
          ${ROOT}/selfhost/decimal.xtpl ${ROOT}/selfhost/typed.xtpl ${ROOT}/selfhost/facts.xtpl
          ${ROOT}/selfhost/bytecode.xtpl ${ROOT}/selfhost/xcb.xtpl)
  get_filename_component(name ${m} NAME_WE)
  execute_process(COMMAND ${XC} --bytecode ${m} ${WORK}/${name}.xbc
                  RESULT_VARIABLE r OUTPUT_VARIABLE said ERROR_VARIABLE said)
  if(NOT r EQUAL 0)
    message(FATAL_ERROR "  ${m}: xc says\n${said}")
  endif()
  list(APPEND modules ${WORK}/${name}.xbc)
endforeach()

# ---- the sources -------------------------------------------------------------
set(sources "")
foreach(d ${DIRS})
  file(GLOB found ${ROOT}/${d}/*.xtpl ${ROOT}/${d}/*.prw ${ROOT}/${d}/*.val)
  list(APPEND sources ${found})
endforeach()
list(SORT sources)
set(list "")
set(vlist "")
set(n 0)
set(compiled "")
foreach(s ${sources})
  file(RELATIVE_PATH rel ${ROOT} ${s})
  string(REPLACE "/" "~" key "${rel}")
  set(mode --bare --facts)
  if(s MATCHES "[.]val$")
    set(mode --values)
  endif()
  execute_process(COMMAND ${AST} ${mode} ${s} ${WORK}/expect/${key}.ast RESULT_VARIABLE r)
  if(NOT r EQUAL 0)
    message(FATAL_ERROR "  xc-ast failed on ${rel}")
  endif()
  if(s MATCHES "[.]val$")
    string(APPEND vlist "${s}\t${WORK}/got/${key}.ast\n")
  else()
    # The .xbc of a source the tree of 'xc-ast --bare' holds: not of one
    # that needs its own commands.
    file(STRINGS ${WORK}/expect/${key}.ast head LIMIT_COUNT 1)
    if(NOT head MATCHES "^not parsed")
      execute_process(COMMAND ${XC} --bytecode ${s} ${WORK}/expect/${key}.xbc
                      RESULT_VARIABLE r OUTPUT_VARIABLE said ERROR_VARIABLE said)
      if(r EQUAL 0 AND EXISTS ${WORK}/expect/${key}.xbc)
        list(APPEND compiled ${s})
      else()
        # Refused only for what cannot become bytecode yet, its warnings
        # aside: those lines, each 'LINE: what cannot become bytecode yet'.
        string(REPLACE "${s}:" "" said "${said}")
        string(REGEX REPLACE "[0-9]+: warning: [^\n]*\n" "" said "${said}")
        string(REGEX REPLACE "[0-9]+: [^\n]* cannot become bytecode yet\n" "" rest "${said}")
        if(NOT said STREQUAL "" AND rest STREQUAL "")
          file(WRITE ${WORK}/expect/${key}.xbc "${said}")
          list(APPEND compiled ${s})
        endif()
      endif()
    endif()
    string(APPEND list "${s}\t${WORK}/got/${key}.ast\t${WORK}/got/${key}.xbc\n")
  endif()
  math(EXPR n "${n} + 1")
endforeach()
file(WRITE ${WORK}/list.txt "${list}")
file(WRITE ${WORK}/values.txt "${vlist}")

foreach(what facts values)
  set(l ${WORK}/list.txt)
  if(what STREQUAL "values")
    set(l ${WORK}/values.txt)
  endif()
  execute_process(COMMAND ${VM} --run=U_XCB ${modules} -- ${what} ${l}
                  RESULT_VARIABLE r OUTPUT_VARIABLE said ERROR_VARIABLE said)
  if(NOT r EQUAL 0)
    message(FATAL_ERROR "  xc-vm (${what}): exit ${r}\n${said}")
  endif()
endforeach()

# ---- what each says ----------------------------------------------------------
set(wrong "")
set(same 0)
foreach(s ${sources})
  file(RELATIVE_PATH rel ${ROOT} ${s})
  string(REPLACE "/" "~" key "${rel}")
  execute_process(COMMAND ${CMAKE_COMMAND} -E compare_files ${WORK}/expect/${key}.ast ${WORK}/got/${key}.ast
                  RESULT_VARIABLE r)
  if(r EQUAL 0)
    math(EXPR same "${same} + 1")
  else()
    string(APPEND wrong "\n    ${rel}")
  endif()
endforeach()
set(nx 0)
set(samex 0)
foreach(s ${compiled})
  file(RELATIVE_PATH rel ${ROOT} ${s})
  string(REPLACE "/" "~" key "${rel}")
  math(EXPR nx "${nx} + 1")
  execute_process(COMMAND ${CMAKE_COMMAND} -E compare_files ${WORK}/expect/${key}.xbc ${WORK}/got/${key}.xbc
                  RESULT_VARIABLE r)
  if(r EQUAL 0)
    math(EXPR samex "${samex} + 1")
  else()
    string(APPEND wrong "\n    ${rel} (.xbc)")
  endif()
endforeach()
if(wrong)
  message(FATAL_ERROR "  ${same} of ${n} trees and ${samex} of ${nx} .xbc the same; these differ "
                      "(${WORK}/expect, got):${wrong}")
endif()
message("  ${same} of ${n} trees and ${samex} of ${nx} .xbc the same")
