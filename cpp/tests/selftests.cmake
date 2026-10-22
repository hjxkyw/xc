# The self-tests an AppServer runs (run-protheus.raku) -- xtpl's
# xtpl/tests/54_selftest.xtpl and xc's protheus/xc_selftest.xtpl --, as
# bytecode, run by xc-vm after xtpl's runtime, compiled to bytecode too: each
# has to end with its total and no check failed.
#
#   cmake -DXC=cpp/build/xc -DVM=cpp/build/xc-vm -DROOT=. -DWORK=cpp/build/selftests -P cpp/tests/selftests.cmake

foreach(v XC VM ROOT WORK)
  get_filename_component(${v} "${${v}}" ABSOLUTE)
endforeach()
file(REMOVE_RECURSE ${WORK})
file(MAKE_DIRECTORY ${WORK})

# compile(SOURCE NAME): SOURCE as WORK/NAME.xbc, or the test fails.
function(compile source name)
  execute_process(COMMAND ${XC} --bytecode ${ROOT}/${source} ${WORK}/${name}.xbc
                  OUTPUT_QUIET
                  ERROR_VARIABLE said
                  RESULT_VARIABLE code)
  if(NOT code EQUAL 0)
    message(FATAL_ERROR "  ${source} does not become bytecode:\n${said}")
  endif()
endfunction()

compile(runtime/xtpl_runtime.tlpp xtpl_runtime)
set(failed "")
foreach(test "xtpl/tests/54_selftest.xtpl;54_selftest;U_SELFTEST;selftest: [0-9]+ ok, 0 falhas"
             "protheus/xc_selftest.xtpl;xc_selftest;U_XC_SELFTEST;xc_selftest: [0-9]+ ok, 0 failed")
  list(GET test 0 source)
  list(GET test 1 name)
  list(GET test 2 entry)
  list(GET test 3 total)
  compile(${source} ${name})
  execute_process(COMMAND ${VM} --run=${entry} ${WORK}/xtpl_runtime.xbc ${WORK}/${name}.xbc
                  OUTPUT_VARIABLE out
                  ERROR_VARIABLE err
                  RESULT_VARIABLE code)
  string(REGEX MATCH "${total}\r?\n?$" last "${out}")
  if(code EQUAL 0 AND last AND err STREQUAL "")
    string(STRIP "${last}" last)
    message("  ${last}")
  else()
    list(APPEND failed ${name})
    message("  FAIL  ${name} (exit ${code})\n--- output\n${out}--- errors\n${err}")
  endif()
endforeach()
if(failed)
  message(FATAL_ERROR "  self-tests that failed on xc-vm: ${failed}")
endif()
