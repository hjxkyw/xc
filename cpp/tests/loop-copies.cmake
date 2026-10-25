# The interpreter's loop, Run() of interp/xbc.xtpl, three times again under
# other names -- Run1(), Run2(), Run3() --, and Enter(), which runs a block
# in Run(), with each -- Enter1() running it in Run1(), ... --, between the
# lines '// >>> the loop's copies' and '// <<< the loop's copies': the
# AppServer enters a function that is already running further down at a
# cost that grows with its size, and a run inside a run is the next copy
# instead. ctest's interp checks them; after a change of Run() or Enter(),
# write them again:
#
#   cmake -DROOT=. -DUPDATE=1 -P cpp/tests/loop-copies.cmake

cmake_policy(SET CMP0054 NEW)
get_filename_component(ROOT "${ROOT}" ABSOLUTE)
set(source ${ROOT}/interp/xbc.xtpl)
file(READ ${source} text)
string(REPLACE "\r\n" "\n" text "${text}")
# method(HEAD NAME RESULT): the method of interp/xbc.xtpl that starts with
# the line HEAD, to its 'Return xResult'.
function(method head name result)
  string(FIND "${text}" "${head}" from)
  if(from EQUAL -1)
    message(FATAL_ERROR "  interp/xbc.xtpl: no '${head}'")
  endif()
  string(SUBSTRING "${text}" ${from} -1 rest)
  string(FIND "${rest}" "\nReturn xResult\n" end)
  if(end EQUAL -1)
    message(FATAL_ERROR "  interp/xbc.xtpl: ${name}() does not end with 'Return xResult'")
  endif()
  math(EXPR end "${end} + 16")
  string(SUBSTRING "${rest}" 0 ${end} body)
  set(${result} "${body}" PARENT_SCOPE)
endfunction()

set(run_head "Method Run(nBase) Class XbcVM\n")
set(enter_head "Method Enter(aClo, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12) Class XbcVM\n")
method("${run_head}" Run loop)
method("${enter_head}" Enter enter)
set(copies "")
foreach(n 1 2 3)
  if(n GREATER 1)
    string(APPEND copies "\n")
  endif()
  string(REPLACE "${run_head}" "Method Run${n}(nBase) Class XbcVM\n" one "${loop}")
  string(APPEND copies "${one}\n")
  string(REPLACE "Method Enter(" "Method Enter${n}(" one "${enter}")
  string(REPLACE "::Run(" "::Run${n}(" one "${one}")
  string(APPEND copies "${one}")
endforeach()

set(open "// >>> the loop's copies\n")
set(close "// <<< the loop's copies\n")
string(FIND "${text}" "${open}" from)
string(FIND "${text}" "${close}" to)
if(from EQUAL -1 OR to EQUAL -1 OR to LESS from)
  message(FATAL_ERROR "  interp/xbc.xtpl: no lines '// >>> the loop's copies' and '// <<< the loop's copies'")
endif()
string(LENGTH "${open}" skip)
math(EXPR start "${from} + ${skip}")
math(EXPR length "${to} - ${start}")
string(SUBSTRING "${text}" ${start} ${length} have)
if(have STREQUAL copies)
  return()
endif()
if(UPDATE)
  string(SUBSTRING "${text}" 0 ${start} before)
  string(SUBSTRING "${text}" ${to} -1 after)
  file(WRITE ${source} "${before}${copies}${after}")
  message("  interp/xbc.xtpl: the loop's copies written again")
else()
  message(FATAL_ERROR "  interp/xbc.xtpl: the loop's copies are not Run()'s and Enter()'s; "
                      "write them again: cmake -DROOT=. -DUPDATE=1 -P cpp/tests/loop-copies.cmake")
endif()
