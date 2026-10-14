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

add_executable(xc
  src/ahead.cpp
  src/chains.cpp
  src/chars.cpp
  src/check.cpp
  src/commands.cpp
  src/emit.cpp
  src/json.cpp
  src/lower.cpp
  src/main.cpp
  src/parser.cpp
  src/statements.cpp
  src/text.cpp
  src/walk.cpp
)

if(MSVC)
  target_compile_options(xc PRIVATE /W4 /permissive- /utf-8)
else()
  target_compile_options(xc PRIVATE -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wno-sign-conversion)
endif()
