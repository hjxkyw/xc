# The compiler written in xtpl (selfhost/), held to the C++ xc: xc compiles
# it to bytecode, xc-vm runs it -- after xtpl's runtime -- over each source
# of the folders given, and the tree it reads each into must be the one
# 'xc-ast --bare' writes, byte for byte.
#
#   cmake -DXC=cpp/build/xc -DVM=cpp/build/xc-vm -DAST=cpp/build/xc-ast
#         -DROOT=. -DWORK=cpp/build/selfhost -P cpp/tests/selfhost.cmake
#
# CMake runs it as a test (ctest). DIRS (';'-separated, under ROOT) are the
# folders whose .xtpl and .prw are read; selfhost/tests when none is given.

get_filename_component(ROOT "${ROOT}" ABSOLUTE)
if(NOT DIRS)
  set(DIRS selfhost/tests)
endif()
file(REMOVE_RECURSE ${WORK})
file(MAKE_DIRECTORY ${WORK}/expect ${WORK}/got)

# ---- the compiler, as bytecode -----------------------------------------------
set(modules "")
foreach(m ${ROOT}/runtime/xtpl_runtime.tlpp ${ROOT}/selfhost/ast.xtpl ${ROOT}/selfhost/dump.xtpl
          ${ROOT}/selfhost/parse.xtpl ${ROOT}/selfhost/xcb.xtpl)
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
  file(GLOB found ${ROOT}/${d}/*.xtpl ${ROOT}/${d}/*.prw)
  list(APPEND sources ${found})
endforeach()
list(SORT sources)
set(list "")
set(n 0)
foreach(s ${sources})
  file(RELATIVE_PATH rel ${ROOT} ${s})
  string(REPLACE "/" "~" key "${rel}")
  execute_process(COMMAND ${AST} --bare ${s} ${WORK}/expect/${key}.ast RESULT_VARIABLE r)
  if(NOT r EQUAL 0)
    message(FATAL_ERROR "  xc-ast failed on ${rel}")
  endif()
  string(APPEND list "${s}\t${WORK}/got/${key}.ast\n")
  math(EXPR n "${n} + 1")
endforeach()
file(WRITE ${WORK}/list.txt "${list}")

execute_process(COMMAND ${VM} --run=U_XCB ${modules} -- ast ${WORK}/list.txt
                RESULT_VARIABLE r OUTPUT_VARIABLE said ERROR_VARIABLE said)
if(NOT r EQUAL 0)
  message(FATAL_ERROR "  xc-vm: exit ${r}\n${said}")
endif()

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
if(wrong)
  message(FATAL_ERROR "  ${same} of ${n} trees the same; these differ (${WORK}/expect, got):${wrong}")
endif()
message("  ${same} of ${n} trees the same")
