cmake_minimum_required(VERSION 3.16)
project(lbs_native_tests CXX C)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

include("${CMAKE_CURRENT_LIST_DIR}/../../src/CMakeLists.txt")

add_executable(lbs_decoder_test
  "${CMAKE_CURRENT_LIST_DIR}/decoder_test.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/fixture.cpp"
  ${LBS_FFI_SOURCES})

target_link_libraries(lbs_decoder_test PRIVATE lbs_core)
target_compile_definitions(lbs_decoder_test PRIVATE
  LBS_FIXTURE_DIR="${CMAKE_CURRENT_LIST_DIR}/fixtures")

add_executable(lbs_benchmark
  "${CMAKE_CURRENT_LIST_DIR}/benchmark.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/fixture.cpp")

target_link_libraries(lbs_benchmark PRIVATE lbs_core)
target_compile_definitions(lbs_benchmark PRIVATE
  LBS_FIXTURE_DIR="${CMAKE_CURRENT_LIST_DIR}/fixtures")

enable_testing()
add_test(NAME decoder COMMAND lbs_decoder_test)
