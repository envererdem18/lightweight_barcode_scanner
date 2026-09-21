# Shared barcode decoding core.
#
# Included by the Android build (android/src/main/cpp/CMakeLists.txt) and by the
# host test harness (test/native). iOS does not use CMake: CocoaPods compiles
# the very same sources, see ios/lightweight_barcode_scanner.podspec.

cmake_minimum_required(VERSION 3.16)

set(LBS_SRC_DIR "${CMAKE_CURRENT_LIST_DIR}")
set(LBS_ZXING_DIR "${CMAKE_CURRENT_LIST_DIR}/../third_party/zxing-cpp/core")

if(NOT EXISTS "${LBS_ZXING_DIR}/generated/Version.h")
  message(FATAL_ERROR "Vendored ZXing-C++ is missing. Run tool/vendor_zxing.sh")
endif()

# The vendored tree is pruned to exactly the files upstream's CMake selects for
# our feature flags, so a glob is both safe and self-maintaining.
file(GLOB_RECURSE LBS_ZXING_SOURCES CONFIGURE_DEPENDS
  "${LBS_ZXING_DIR}/src/*.cpp"
  "${LBS_ZXING_DIR}/src/*.c")

add_library(lbs_core STATIC
  ${LBS_ZXING_SOURCES}
  "${LBS_SRC_DIR}/barcode_decoder.cpp")

# The FFI shim is deliberately *not* part of lbs_core: its symbols are only
# reachable from Dart, so a static library would let the linker drop them.
# Every shared/executable target that needs them compiles this file directly.
set(LBS_FFI_SOURCES "${LBS_SRC_DIR}/lbs_ffi.cpp")

target_include_directories(lbs_core PUBLIC
  "${LBS_SRC_DIR}"
  "${LBS_ZXING_DIR}/src"
  "${LBS_ZXING_DIR}/generated")

# ZXing headers expose extra internals to translation units that are part of the
# library itself; our decoder is one of them.
target_compile_definitions(lbs_core PUBLIC ZXING_INTERNAL)

target_compile_features(lbs_core PUBLIC cxx_std_20)
set_target_properties(lbs_core PROPERTIES
  POSITION_INDEPENDENT_CODE ON
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)

if(NOT MSVC)
  # Keeps every symbol in its own section so the linker can drop the parts of
  # ZXing we never call (see docs/ARCHITECTURE.md, "Binary size").
  target_compile_options(lbs_core PRIVATE
    -ffunction-sections -fdata-sections -fno-strict-aliasing)
endif()
