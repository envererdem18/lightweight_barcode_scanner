# The JNI bridge constructs this class by name and signature.
-keep class dev.enver.lightweight_barcode_scanner.NativeBarcode { *; }
-keepclasseswithmembernames class dev.enver.lightweight_barcode_scanner.NativeDecoder {
    native <methods>;
}
