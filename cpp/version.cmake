# The commit xc is built from, for 'xc --version': version.h, written at
# each build -- and only when what it says changed, so that nothing is
# compiled again for nothing.
#
#   cmake -DSRC=<the repository> -DDST=<version.h> -P version.cmake
#
# The commit is git's short hash, '-dirty' after it when the tracked files
# differ from it; its date is the commit's. Without git, or outside a
# clone: 'unknown'.

set(commit "unknown")
set(date "unknown")
find_package(Git QUIET)
if(GIT_FOUND)
  execute_process(COMMAND ${GIT_EXECUTABLE} describe --always --dirty
                  WORKING_DIRECTORY ${SRC}
                  OUTPUT_VARIABLE out
                  ERROR_QUIET
                  RESULT_VARIABLE code
                  OUTPUT_STRIP_TRAILING_WHITESPACE)
  if(code EQUAL 0 AND NOT out STREQUAL "")
    set(commit "${out}")
    execute_process(COMMAND ${GIT_EXECUTABLE} log -1 --format=%cd --date=short
                    WORKING_DIRECTORY ${SRC}
                    OUTPUT_VARIABLE out
                    ERROR_QUIET
                    RESULT_VARIABLE code
                    OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(code EQUAL 0 AND NOT out STREQUAL "")
      set(date "${out}")
    endif()
  endif()
endif()

set(text "// Written by version.cmake at each build: the commit xc is built from.\n#pragma once\n#define XC_COMMIT \"${commit}\"\n#define XC_DATE \"${date}\"\n")
set(old "")
if(EXISTS ${DST})
  file(READ ${DST} old)
endif()
if(NOT old STREQUAL text)
  file(WRITE ${DST} "${text}")
endif()
