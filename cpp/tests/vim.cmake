# Vim's syntax file for xtpl (editors/vim), held to editors/vim/test/
# syntax.vim: each piece of xtpl there in the group given, and no .xtpl of
# the repository left inside a block comment or a directive at its end.
#
#   cmake -DVIM=vim -DROOT=. -DWORK=cpp/build/vim -P cpp/tests/vim.cmake
#
# CMake runs it as a test (ctest), when it finds a vim.

get_filename_component(ROOT "${ROOT}" ABSOLUTE)
file(REMOVE_RECURSE ${WORK})
file(MAKE_DIRECTORY ${WORK})
# Vim reads commands from its input when its script is done: none.
file(WRITE ${WORK}/none "")
execute_process(COMMAND ${VIM} -Nu NONE -i NONE -n -es --cmd "let g:out = '${WORK}/vim.out'"
                        -S ${ROOT}/editors/vim/test/syntax.vim
                INPUT_FILE ${WORK}/none
                RESULT_VARIABLE r OUTPUT_QUIET ERROR_QUIET)
set(said "")
if(EXISTS ${WORK}/vim.out)
  file(READ ${WORK}/vim.out said)
endif()
if(NOT r EQUAL 0)
  message(FATAL_ERROR "  vim (exit ${r}):\n${said}")
endif()
string(REGEX MATCH "[0-9]+ of [0-9]+" total "${said}")
message("  ${total} as the syntax file has them")
