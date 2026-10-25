# The bytecode's interpreter written in xtpl (interp/xbc.xtpl), run by xc-vm:
# xc-vm runs the interpreter -- after xtpl's runtime, which the interpreter
# uses, as the AppServer has it in its RPO --, and the interpreter runs the
# program: xtpl's runtime and the program, both bytecode, both interpreted.
# What it writes (--out) has to be what xc-vm does running the program
# itself: each case of cpp/tests/bytecode that has a NAME.out, and xtpl's
# self-test; with -DMODE=xc, xc's self-test instead (it walks arrays of
# 40,000 through two machines: tens of seconds).
#
#   cmake -DXC=cpp/build/xc -DVM=cpp/build/xc-vm -DROOT=. -DWORK=cpp/build/interp -P cpp/tests/interp.cmake
#
# xtpl's self-test runs a second time without the runtime's bytecode: the
# runtime's calls are the AppServer's then -- the interpreter's table of
# them, on xc-vm its own runtime. And the table has to have each of the
# runtime's functions (runtime-calls.cmake).
#
# CMake runs it as a test (ctest), 'interp' and 'interp-xc'. "\r\n" is read
# as "\n".

cmake_policy(SET CMP0012 NEW)
cmake_policy(SET CMP0054 NEW)
cmake_policy(SET CMP0007 NEW)
foreach(v XC VM ROOT WORK)
  get_filename_component(${v} "${${v}}" ABSOLUTE)
endforeach()
set(CASES ${ROOT}/cpp/tests/bytecode)
file(REMOVE_RECURSE ${WORK})
file(MAKE_DIRECTORY ${WORK})

# compile(SOURCE NAME): SOURCE as WORK/NAME.xbc, or the test fails.
function(compile source name)
  execute_process(COMMAND ${XC} --bytecode ${source} ${WORK}/${name}.xbc
                  OUTPUT_QUIET
                  ERROR_VARIABLE said
                  RESULT_VARIABLE code)
  if(NOT code EQUAL 0)
    message(FATAL_ERROR "  ${source} does not become bytecode:\n${said}")
  endif()
endfunction()

# interpret(NAME RESULT ARGS...): the interpreter run on the modules ARGS, its
# --out in RESULT.
function(interpret name result)
  execute_process(COMMAND ${VM} --run=U_XBC ${WORK}/xtpl_runtime.xbc ${WORK}/xbc.xbc -- --out=${WORK}/${name}.got ${ARGN}
                  WORKING_DIRECTORY ${CASES}
                  OUTPUT_VARIABLE out
                  ERROR_VARIABLE err
                  RESULT_VARIABLE code)
  set(got "")
  if(EXISTS ${WORK}/${name}.got)
    file(READ ${WORK}/${name}.got got)
  endif()
  if(NOT code EQUAL 0 AND NOT code EQUAL 1)
    set(got "${got}--- xc-vm, running the interpreter: exit ${code}\n${out}${err}")
  endif()
  string(REPLACE "\r\n" "\n" got "${got}")
  set(${result} "${got}" PARENT_SCOPE)
endfunction()

# As TL++, for the AppServer, it has to say nothing: a warning there -- a
# 'Recover Using', which the AppServer gets wrong -- is one the bytecode
# does not show.
execute_process(COMMAND ${XC} --check ${ROOT}/interp/xbc.xtpl
                OUTPUT_VARIABLE said
                ERROR_VARIABLE said
                RESULT_VARIABLE code)
if(NOT code EQUAL 0 OR said MATCHES "warning")
  message(FATAL_ERROR "  interp/xbc.xtpl, as TL++:\n${said}")
endif()
include(${CMAKE_CURRENT_LIST_DIR}/runtime-calls.cmake)
compile(${ROOT}/interp/xbc.xtpl xbc)
compile(${ROOT}/runtime/xtpl_runtime.tlpp xtpl_runtime)
set(failed "")
set(count 0)

if(MODE STREQUAL "xc")
  set(selftests "protheus/xc_selftest.xtpl|xc_selftest|U_XC_SELFTEST|xc_selftest: [0-9]+ ok, 0 failed|runtime")
else()
  set(selftests "xtpl/tests/54_selftest.xtpl|54_selftest|U_SELFTEST|selftest: [0-9]+ ok, 0 falhas|runtime"
                "xtpl/tests/54_selftest.xtpl|54_selftest|U_SELFTEST|selftest: [0-9]+ ok, 0 falhas|")
  file(GLOB outs RELATIVE ${CASES} ${CASES}/*.out)
  list(SORT outs)
  foreach(o ${outs})
    string(REGEX REPLACE "\\.out$" "" name ${o})
    file(GLOB src ${CASES}/${name}.xtpl ${CASES}/${name}.prw)
    compile(${src} ${name})
  endforeach()
  foreach(o ${outs})
    string(REGEX REPLACE "\\.out$" "" name ${o})
    math(EXPR count "${count} + 1")
    set(with "")
    if(EXISTS ${CASES}/${name}.with)
      file(STRINGS ${CASES}/${name}.with names)
      foreach(w ${names})
        list(APPEND with ${WORK}/${w}.xbc)
      endforeach()
    endif()
    interpret(${name} got ${WORK}/xtpl_runtime.xbc ${with} ${WORK}/${name}.xbc)
    file(READ ${CASES}/${o} expect)
    string(REPLACE "\r\n" "\n" expect "${expect}")
    if(NOT got STREQUAL expect)
      list(APPEND failed ${name})
      message("  FAIL  ${name}\n--- expected\n${expect}--- got\n${got}")
    endif()
  endforeach()
endif()

foreach(test ${selftests})
  string(REPLACE "|" ";" parts "${test}")
  list(GET parts 0 source)
  list(GET parts 1 name)
  list(GET parts 2 entry)
  list(GET parts 3 total)
  list(LENGTH parts nparts)
  set(runtime "")
  set(how " (its calls of the runtime the AppServer's)")
  if(nparts GREATER 4)
    list(GET parts 4 with)
    if(with STREQUAL "runtime")
      set(runtime ${WORK}/xtpl_runtime.xbc)
      set(how "")
    endif()
  endif()
  math(EXPR count "${count} + 1")
  compile(${ROOT}/${source} ${name})
  interpret(${name} got --run=${entry} ${runtime} ${WORK}/${name}.xbc)
  if(got MATCHES "^exit 0\n--- output\n.*${total}\n--- errors\n$")
    string(REGEX MATCH "${total}" last "${got}")
    message("  ${last}${how}")
  else()
    list(APPEND failed ${name})
    message("  FAIL  ${name}${how}\n${got}")
  endif()
endforeach()

if(failed)
  list(LENGTH failed n)
  message(FATAL_ERROR "  ${n} of ${count} differ through the interpreter: ${failed}")
endif()
message("  ${count} of ${count} through the interpreter")
