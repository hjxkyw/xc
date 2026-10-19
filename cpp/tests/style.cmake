# The house style that a test can see: a separator line -- a comment that is
# a run of dashes, with a title in it or not -- ends at column 80, in xc's
# own files: the C++ sources, the CMake files, the scripts, the self-test and
# the runtime. xtpl/ is xtpl's, as it came, and the cases are data: neither
# is looked at.
#
#   cmake -DROOT=. -P cpp/tests/style.cmake
#
# CMake runs it as a test (ctest). A file is read as bytes: a separator is
# ASCII, and the windows-1252 around it is not looked at. A "\r" is not
# counted.

get_filename_component(ROOT "${ROOT}" ABSOLUTE)

file(GLOB_RECURSE files LIST_DIRECTORIES false
     ${ROOT}/cpp/src/* ${ROOT}/protheus/* ${ROOT}/runtime/*)
file(GLOB more LIST_DIRECTORIES false
     ${ROOT}/cpp/CMakeLists.txt ${ROOT}/cpp/*.cmake ${ROOT}/cpp/tests/*.cmake ${ROOT}/*.raku)
list(APPEND files ${more})
list(SORT files)

set(seen 0)
set(wrong "")
foreach(f ${files})
  file(STRINGS ${f} lines REGEX "^[ \t]*(#|//)[ \t]?----")
  foreach(l ${lines})
    string(REGEX REPLACE "[ \t\r]+$" "" l "${l}")
    math(EXPR seen "${seen} + 1")
    string(LENGTH "${l}" n)
    if(NOT n EQUAL 80)
      file(RELATIVE_PATH r ${ROOT} ${f})
      string(APPEND wrong "\n    ${r}: ${n} columns: ${l}")
    endif()
  endforeach()
endforeach()

if(seen LESS 50)
  message(FATAL_ERROR "  only ${seen} separator lines found: the files moved?")
endif()
if(wrong)
  message(FATAL_ERROR "  separator lines that do not end at column 80:${wrong}")
endif()
message("  ${seen} separator lines, each ending at column 80")
