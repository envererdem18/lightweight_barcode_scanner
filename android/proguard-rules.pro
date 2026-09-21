# The JNI bridge constructs this class by name and signature.
-keep class com.enver.lightweight_barcode_scanner.NativeBarcode { *; }
-keepclasseswithmembernames class com.enver.lightweight_barcode_scanner.NativeDecoder {
    native <methods>;
}
