# xc's bytecode, as data (cpp/tests/bytecode): each NAME.xtpl (or NAME.prw)
# is compiled with 'xc --bytecode'. NAME.xbc is what it writes; NAME.err what
# it says, warnings or why it writes nothing, when it says anything; NAME.out,
# when there is one, what xc-vm does running the .xbc after xtpl's runtime
# (RUNTIME, compiled the same way) and the cases NAME.with names, one to a
# line, from that folder -- its exit code, what it printed on its output and
# on its errors.
#
#   cmake -DXC=cpp/build/xc -DVM=cpp/build/xc-vm -DRUNTIME=runtime/xtpl_runtime.tlpp
#         -DCASES=cpp/tests/bytecode -DWORK=cpp/build/bytecode -P cpp/tests/bytecode.cmake
#   ... -DUPDATE=1      writes the expected files again, after a change that is meant --
#                       a NAME.out only where there is one: an empty one asks for it
#
# CMake runs it as a test (ctest). "\r\n" is read as "\n".

cmake_policy(SET CMP0012 NEW)
foreach(v XC VM RUNTIME CASES WORK)
  get_filename_component(${v} "${${v}}" ABSOLUTE)
endforeach()

file(GLOB sources RELATIVE ${CASES} ${CASES}/*.xtpl ${CASES}/*.prw)
list(SORT sources)
file(REMOVE_RECURSE ${WORK})
file(MAKE_DIRECTORY ${WORK})
execute_process(COMMAND ${XC} --bytecode ${RUNTIME} ${WORK}/xtpl_runtime.xbc
                OUTPUT_QUIET
                ERROR_VARIABLE said
                RESULT_VARIABLE code)
if(NOT code EQUAL 0)
  message(FATAL_ERROR "  the runtime does not become bytecode:\n${said}")
endif()
set(failed "")
set(count 0)

# check(NAME EXT GOT REMOVE): GOT against what NAME.EXT holds, "" when there
# is none; with UPDATE, written there instead -- or the file removed, when GOT
# is "" and REMOVE is set.
function(check name ext got remove)
  set(file ${CASES}/${name}.${ext})
  if(UPDATE)
    if(got STREQUAL "" AND remove)
      file(REMOVE ${file})
    else()
      file(WRITE ${file} "${got}")
    endif()
    return()
  endif()
  set(expect "")
  if(EXISTS ${file})
    file(READ ${file} expect)
    string(REPLACE "\r\n" "\n" expect "${expect}")
  endif()
  if(NOT got STREQUAL expect)
    set(failed ${failed} "${name}.${ext}" PARENT_SCOPE)
    message("  FAIL  ${name}.${ext}\n--- expected\n${expect}--- got\n${got}")
  endif()
endfunction()

foreach(src ${sources})
  string(REGEX REPLACE "\\.[^.]*$" "" name ${src})
  math(EXPR count "${count} + 1")
  execute_process(COMMAND ${XC} --bytecode ${src} ${WORK}/${name}.xbc
                  WORKING_DIRECTORY ${CASES}
                  OUTPUT_QUIET
                  ERROR_VARIABLE said)
  string(REPLACE "\r\n" "\n" said "${said}")
  check(${name} err "${said}" ON)
  set(made "")
  if(EXISTS ${WORK}/${name}.xbc)
    file(READ ${WORK}/${name}.xbc made)
    string(REPLACE "\r\n" "\n" made "${made}")
  endif()
  check(${name} xbc "${made}" ON)
  if(EXISTS ${CASES}/${name}.out AND EXISTS ${WORK}/${name}.xbc)
    set(with "")
    if(EXISTS ${CASES}/${name}.with)
      file(STRINGS ${CASES}/${name}.with names)
      foreach(w ${names})
        list(APPEND with ${WORK}/${w}.xbc)
      endforeach()
    endif()
    execute_process(COMMAND ${VM} ${WORK}/xtpl_runtime.xbc ${with} ${WORK}/${name}.xbc
                    WORKING_DIRECTORY ${CASES}
                    OUTPUT_VARIABLE out
                    ERROR_VARIABLE err
                    RESULT_VARIABLE code)
    set(ran "exit ${code}\n--- output\n${out}--- errors\n${err}")
    string(REPLACE "\r\n" "\n" ran "${ran}")
    check(${name} out "${ran}" OFF)
  endif()
endforeach()

if(UPDATE)
  message("  ${count} bytecode cases written")
elseif(failed)
  list(LENGTH failed n)
  message(FATAL_ERROR "  ${n} files of ${count} bytecode cases differ: ${failed}")
else()
  message("  ${count} of ${count} bytecode cases")
endif()
