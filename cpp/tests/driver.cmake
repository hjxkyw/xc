# xc's command line, as data (cpp/tests/driver): each NAME.cmd is the
# arguments of one run, one to a line; NAME.expect what the run did -- its
# exit code, what it printed on its output and on its errors, and the .tlpp
# files it wrote. Each runs in a fresh copy of src/ and extra/, the files the
# arguments name.
#
#   cmake -DXC=cpp/build/xc -DCASES=cpp/tests/driver -DWORK=cpp/build/driver -P cpp/tests/driver.cmake
#   ... -DUPDATE=1      writes the NAME.expect files again, after a change that is meant
#
# CMake runs it as a test (ctest). A '\' in what xc prints is read as '/', and
# "\r\n" as "\n": the expected files hold for Windows too. What --version
# says is read as 'xc version COMMIT, DATE'.

# Paths given relative are from where it runs.
foreach(v XC CASES WORK)
  get_filename_component(${v} "${${v}}" ABSOLUTE)
endforeach()

file(GLOB cmds RELATIVE ${CASES} ${CASES}/*.cmd)
list(SORT cmds)
set(failed "")
set(count 0)
foreach(cmd ${cmds})
  string(REGEX REPLACE "\\.cmd$" "" name ${cmd})
  set(run ${WORK}/${name})
  file(REMOVE_RECURSE ${run})
  file(MAKE_DIRECTORY ${run})
  file(COPY ${CASES}/src ${CASES}/extra DESTINATION ${run})
  file(STRINGS ${CASES}/${cmd} args)
  execute_process(COMMAND ${XC} ${args}
                  WORKING_DIRECTORY ${run}
                  OUTPUT_VARIABLE out
                  ERROR_VARIABLE err
                  RESULT_VARIABLE code)
  file(GLOB_RECURSE written RELATIVE ${run} ${run}/*.tlpp)
  list(SORT written)
  string(REPLACE ";" "\n" written "${written}")
  set(got "exit ${code}\n--- output\n${out}--- errors\n${err}--- written\n${written}\n")
  string(REPLACE "\r\n" "\n" got "${got}")
  string(REPLACE "\\" "/" got "${got}")
  # The commit xc is built from changes with each one.
  string(REGEX REPLACE "xc version [^\n]*" "xc version COMMIT, DATE" got "${got}")
  math(EXPR count "${count} + 1")
  if(UPDATE)
    file(WRITE ${CASES}/${name}.expect "${got}")
  else()
    set(expect "")
    if(EXISTS ${CASES}/${name}.expect)
      file(READ ${CASES}/${name}.expect expect)
    endif()
    if(NOT got STREQUAL expect)
      list(APPEND failed ${name})
      message("  FAIL  ${name}\n--- expected\n${expect}--- got\n${got}")
    endif()
  endif()
endforeach()
if(UPDATE)
  message("  ${count} driver cases written")
elseif(failed)
  list(LENGTH failed n)
  message(FATAL_ERROR "  ${n} of ${count} driver cases differ: ${failed}")
else()
  message("  ${count} of ${count} driver cases")
endif()
