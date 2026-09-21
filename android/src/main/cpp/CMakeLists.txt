# Android build of the shared decoding core.
#
# Produces libbarcode_scanner.so, which carries three things:
#   * the vendored ZXing-C++ reader core,
#   * the platform-neutral lbs::Decoder,
#   * the JNI entry points used by the camera pipeline and the C ABI used by
#     dart:ffi for still images.

cmake_minimum_required(VERSION 3.22.1)
project(barcode_scanner CXX C)

include("${CMAKE_CURRENT_LIST_DIR}/../../../../src/CMakeLists.txt")

add_library(barcode_scanner SHARED
  "${CMAKE_CURRENT_LIST_DIR}/jni_bridge.cpp"
  ${LBS_FFI_SOURCES})

target_link_libraries(barcode_scanner PRIVATE lbs_core log)

# Only the JNI entry points and the FFI symbols are meant to be visible; with a
# statically linked libc++ this also keeps its symbols out of the dynamic table.
set_target_properties(barcode_scanner PROPERTIES
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)

# Release builds: drop the ZXing code paths nothing calls and keep the .so
# free of debug symbols (Gradle strips as well, this makes it explicit).
target_link_options(barcode_scanner PRIVATE
  "$<$<NOT:$<CONFIG:Debug>>:-Wl,--gc-sections>"
  "$<$<NOT:$<CONFIG:Debug>>:-Wl,--exclude-libs,ALL>"
  "$<$<NOT:$<CONFIG:Debug>>:-s>")
