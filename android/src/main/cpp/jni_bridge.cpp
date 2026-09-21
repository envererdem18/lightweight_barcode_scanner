// JNI bridge between the CameraX analyzer and the shared decoder.
//
// Frame contract for nativeDecode():
//
//   owner        : CameraX (ImageProxy), released by Kotlin right after the
//                  call returns
//   format       : YUV_420_888 plane 0 (luminance)
//   buffer       : a direct ByteBuffer, so we read the camera's own memory
//   lifetime     : the duration of the call
//   thread       : the single-threaded analyzer executor
//   copies       : none

#include <jni.h>

#include <cstring>
#include <string>

#include "barcode_decoder.h"

namespace {

// Cached so a detection does not pay for class lookup.
jclass g_barcode_class = nullptr;
jmethodID g_barcode_ctor = nullptr;

lbs::Decoder* AsDecoder(jlong handle) {
  return reinterpret_cast<lbs::Decoder*>(handle);
}

jobject MakeBarcode(JNIEnv* env, const lbs::DecodeResult& result,
                    bool include_bytes) {
  // ZXing returns UTF-8; NewStringUTF expects modified UTF-8, which differs
  // only for NUL and for code points outside the BMP. Going through a byte
  // array and String(byte[], "UTF-8") would be correct for those too, but it
  // allocates twice; barcode payloads that hit the difference are vanishingly
  // rare and would be read from rawBytes anyway.
  jstring text = env->NewStringUTF(result.text.c_str());
  if (text == nullptr) return nullptr;

  jfloatArray corners = env->NewFloatArray(8);
  if (corners == nullptr) {
    env->DeleteLocalRef(text);
    return nullptr;
  }
  float values[8];
  for (int i = 0; i < 4; ++i) {
    values[i * 2] = result.corners[i].x;
    values[i * 2 + 1] = result.corners[i].y;
  }
  env->SetFloatArrayRegion(corners, 0, 8, values);

  jbyteArray bytes = nullptr;
  if (include_bytes && !result.bytes.empty()) {
    bytes = env->NewByteArray(static_cast<jsize>(result.bytes.size()));
    if (bytes != nullptr) {
      env->SetByteArrayRegion(
          bytes, 0, static_cast<jsize>(result.bytes.size()),
          reinterpret_cast<const jbyte*>(result.bytes.data()));
    }
  }

  jobject barcode = env->NewObject(g_barcode_class, g_barcode_ctor, text,
                                   static_cast<jint>(result.format), corners,
                                   bytes, static_cast<jint>(result.orientation));
  env->DeleteLocalRef(text);
  env->DeleteLocalRef(corners);
  if (bytes != nullptr) env->DeleteLocalRef(bytes);
  return barcode;
}

}  // namespace

extern "C" {

// The package name contains underscores, hence the _1 escapes in these
// symbols (JNI name mangling).
#define LBS_JNI(name) \
  Java_com_enver_lightweight_1barcode_1scanner_NativeDecoder_##name

JNIEXPORT jlong JNICALL LBS_JNI(nativeCreate)(JNIEnv* env, jclass clazz) {
  if (g_barcode_class == nullptr) {
    jclass local = env->FindClass(
        "com/enver/lightweight_barcode_scanner/NativeBarcode");
    if (local == nullptr) return 0;
    g_barcode_class = static_cast<jclass>(env->NewGlobalRef(local));
    env->DeleteLocalRef(local);
    g_barcode_ctor = env->GetMethodID(g_barcode_class, "<init>",
                                      "(Ljava/lang/String;I[F[BI)V");
    if (g_barcode_ctor == nullptr) return 0;
  }
  return reinterpret_cast<jlong>(new lbs::Decoder());
}

JNIEXPORT void JNICALL LBS_JNI(nativeDestroy)(JNIEnv* env, jclass clazz,
                                              jlong handle) {
  delete AsDecoder(handle);
}

JNIEXPORT void JNICALL LBS_JNI(nativeSetOptions)(
    JNIEnv* env, jclass clazz, jlong handle, jint formats, jboolean try_harder,
    jboolean try_rotate, jboolean try_invert, jboolean try_downscale,
    jint max_symbols, jint rotation, jint crop_left, jint crop_top,
    jint crop_width, jint crop_height) {
  lbs::Decoder* decoder = AsDecoder(handle);
  if (decoder == nullptr) return;

  lbs::DecodeOptions options;
  options.formats = static_cast<uint32_t>(formats);
  options.try_harder = try_harder == JNI_TRUE;
  options.try_rotate = try_rotate == JNI_TRUE;
  options.try_invert = try_invert == JNI_TRUE;
  options.try_downscale = try_downscale == JNI_TRUE;
  options.max_symbols = max_symbols;
  options.rotation = rotation;
  options.crop_left = crop_left;
  options.crop_top = crop_top;
  options.crop_width = crop_width;
  options.crop_height = crop_height;
  decoder->SetOptions(options);
}

JNIEXPORT jobjectArray JNICALL LBS_JNI(nativeDecode)(
    JNIEnv* env, jclass clazz, jlong handle, jobject buffer, jint size,
    jint width, jint height, jint row_stride, jint pixel_stride,
    jboolean include_bytes) {
  lbs::Decoder* decoder = AsDecoder(handle);
  if (decoder == nullptr) return nullptr;

  const auto* data =
      static_cast<const uint8_t*>(env->GetDirectBufferAddress(buffer));
  if (data == nullptr) return nullptr;  // not a direct buffer

  const std::vector<lbs::DecodeResult>& results =
      decoder->Decode(data, static_cast<size_t>(size), width, height,
                      row_stride, pixel_stride);
  if (results.empty()) return nullptr;

  jobjectArray array = env->NewObjectArray(
      static_cast<jsize>(results.size()), g_barcode_class, nullptr);
  if (array == nullptr) return nullptr;
  for (size_t i = 0; i < results.size(); ++i) {
    jobject barcode = MakeBarcode(env, results[i], include_bytes == JNI_TRUE);
    if (barcode == nullptr) continue;
    env->SetObjectArrayElement(array, static_cast<jsize>(i), barcode);
    env->DeleteLocalRef(barcode);
  }
  return array;
}

#undef LBS_JNI

}  // extern "C"
