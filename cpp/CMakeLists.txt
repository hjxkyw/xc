# xc in C++: C++20, no modules, nothing beyond the standard library.
#
#   cmake -S cpp -B cpp/build -DCMAKE_BUILD_TYPE=Release
#   cmake --build cpp/build --config Release
#
# Built with GCC and Clang on Linux and with MSVC on Windows.

cmake_minimum_required(VERSION 3.20)
project(xc LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()

# Everything but the programs: the compiler itself.
add_library(xclib STATIC
  src/ahead.cpp
  src/bytecode.cpp
  src/chains.cpp
  src/chars.cpp
  src/check.cpp
  src/commands.cpp
  src/decimal.cpp
  src/driver.cpp
  src/emit.cpp
  src/lower.cpp
  src/parser.cpp
  src/statements.cpp
  src/text.cpp
  src/walk.cpp
)

# xc, the compiler; xc-outputs, which holds xc to the TL++ kept beside
# xtpl's sources; xc-cases, xc's tests as data (cpp/tests/cases);
# xc-doc, which holds docs/language.md to what xc makes of its examples;
# xc-vm, which runs the bytecode 'xc --bytecode' writes (docs/bytecode.md).
add_executable(xc src/xc.cpp)
add_executable(xc-outputs src/outputs.cpp)
add_executable(xc-cases src/cases.cpp)
add_executable(xc-doc src/doc.cpp)
add_executable(xc-vm src/vm.cpp)
target_link_libraries(xc PRIVATE xclib)

# 'xc --version': the commit it is built from, in version.h, written at each
# build (version.cmake).
add_custom_target(xc-version
                  COMMAND ${CMAKE_COMMAND} -DSRC=${PROJECT_SOURCE_DIR}/..
                          -DDST=${CMAKE_CURRENT_BINARY_DIR}/version/version.h -P ${PROJECT_SOURCE_DIR}/version.cmake
                  BYPRODUCTS ${CMAKE_CURRENT_BINARY_DIR}/version/version.h)
add_dependencies(xc xc-version)
target_include_directories(xc PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/version)
target_link_libraries(xc-outputs PRIVATE xclib)
target_link_libraries(xc-cases PRIVATE xclib)
target_link_libraries(xc-doc PRIVATE xclib)

# ctest --test-dir cpp/build
enable_testing()
add_test(NAME outputs
         COMMAND xc-outputs xtpl/tests xtpl/examples
         WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}/..)
add_test(NAME cases
         COMMAND xc-cases cpp/tests/cases
         WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}/..)
add_test(NAME driver
         COMMAND ${CMAKE_COMMAND} -DXC=$<TARGET_FILE:xc> -DCASES=${PROJECT_SOURCE_DIR}/tests/driver
                 -DWORK=${CMAKE_CURRENT_BINARY_DIR}/driver -P ${PROJECT_SOURCE_DIR}/tests/driver.cmake)
add_test(NAME doc
         COMMAND xc-doc docs/language.md ${CMAKE_CURRENT_BINARY_DIR}/doc
         WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}/..)
add_test(NAME style
         COMMAND ${CMAKE_COMMAND} -DROOT=${PROJECT_SOURCE_DIR}/.. -P ${PROJECT_SOURCE_DIR}/tests/style.cmake)
add_test(NAME bytecode
         COMMAND ${CMAKE_COMMAND} -DXC=$<TARGET_FILE:xc> -DVM=$<TARGET_FILE:xc-vm>
                 -DRUNTIME=${PROJECT_SOURCE_DIR}/../runtime/xtpl_runtime.tlpp
                 -DCASES=${PROJECT_SOURCE_DIR}/tests/bytecode -DWORK=${CMAKE_CURRENT_BINARY_DIR}/bytecode
                 -P ${PROJECT_SOURCE_DIR}/tests/bytecode.cmake)
add_test(NAME selftests
         COMMAND ${CMAKE_COMMAND} -DXC=$<TARGET_FILE:xc> -DVM=$<TARGET_FILE:xc-vm> -DROOT=${PROJECT_SOURCE_DIR}/..
                 -DWORK=${CMAKE_CURRENT_BINARY_DIR}/selftests -P ${PROJECT_SOURCE_DIR}/tests/selftests.cmake)

foreach(t xclib xc xc-outputs xc-cases xc-doc xc-vm)
  if(MSVC)
    target_compile_options(${t} PRIVATE /W4 /permissive- /utf-8 /MP)
  else()
    target_compile_options(${t} PRIVATE -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wno-sign-conversion)
  endif()
endforeach()
