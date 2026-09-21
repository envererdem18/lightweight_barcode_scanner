package dev.enver.lightweight_barcode_scanner

import java.nio.ByteBuffer

/** One decoded symbol, as produced by the JNI bridge. */
class NativeBarcode(
    @JvmField val text: String,
    @JvmField val format: Int,
    /** x0, y0 ... x3, y3 in the analysed (rotated, cropped) image. */
    @JvmField val corners: FloatArray,
    @JvmField val bytes: ByteArray?,
    @JvmField val orientation: Int,
)

/**
 * Kotlin handle on a `lbs::Decoder`.
 *
 * One instance belongs to one scanner session and is only ever touched from
 * the analyzer thread, which is what the native decoder expects: it is not
 * internally synchronised, and it reuses its buffers between frames.
 */
class NativeDecoder : AutoCloseable {
    private var handle: Long = nativeCreate()

    val isValid: Boolean get() = handle != 0L

    fun setOptions(
        formats: Int,
        tryHarder: Boolean,
        tryRotate: Boolean,
        tryInvert: Boolean,
        tryDownscale: Boolean,
        maxSymbols: Int,
        rotation: Int,
        cropLeft: Int,
        cropTop: Int,
        cropWidth: Int,
        cropHeight: Int,
    ) {
        if (handle == 0L) return
        nativeSetOptions(
            handle, formats, tryHarder, tryRotate, tryInvert, tryDownscale,
            maxSymbols, rotation, cropLeft, cropTop, cropWidth, cropHeight,
        )
    }

    /**
     * Decodes a luminance plane in place. [buffer] must be a direct
     * [ByteBuffer]; the camera's own plane already is one, so nothing is
     * copied. The buffer only has to stay valid for the duration of the call.
     */
    fun decode(
        buffer: ByteBuffer,
        width: Int,
        height: Int,
        rowStride: Int,
        pixelStride: Int,
        includeBytes: Boolean,
    ): Array<NativeBarcode>? {
        if (handle == 0L || !buffer.isDirect) return null
        @Suppress("UNCHECKED_CAST")
        return nativeDecode(
            handle, buffer, buffer.capacity(), width, height, rowStride,
            pixelStride, includeBytes,
        ) as Array<NativeBarcode>?
    }

    override fun close() {
        if (handle == 0L) return
        nativeDestroy(handle)
        handle = 0L
    }

    private companion object {
        init {
            System.loadLibrary("barcode_scanner")
        }

        @JvmStatic external fun nativeCreate(): Long

        @JvmStatic external fun nativeDestroy(handle: Long)

        @JvmStatic external fun nativeSetOptions(
            handle: Long,
            formats: Int,
            tryHarder: Boolean,
            tryRotate: Boolean,
            tryInvert: Boolean,
            tryDownscale: Boolean,
            maxSymbols: Int,
            rotation: Int,
            cropLeft: Int,
            cropTop: Int,
            cropWidth: Int,
            cropHeight: Int,
        )

        @JvmStatic external fun nativeDecode(
            handle: Long,
            buffer: ByteBuffer,
            size: Int,
            width: Int,
            height: Int,
            rowStride: Int,
            pixelStride: Int,
            includeBytes: Boolean,
        ): Array<Any>?
    }
}
