package com.enver.lightweight_barcode_scanner

import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Size
import android.view.Surface
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * One camera session: CameraX for acquisition, the shared C++ core for
 * decoding, a Flutter texture for the preview.
 *
 * Frame path (see docs/ARCHITECTURE.md):
 *
 *   preview   : camera -> SurfaceTexture -> Flutter texture. GPU only, never
 *               touched by the CPU and never seen by Dart.
 *   analysis  : camera -> ImageProxy (YUV_420_888) -> plane 0 -> C++ decoder.
 *               The plane is a direct ByteBuffer, so nothing is copied. The
 *               proxy is closed as soon as the decode returns, which is what
 *               makes CameraX hand us the *next* frame rather than a queued
 *               one.
 *
 * Everything camera-related happens on the main thread; every decode happens
 * on [analysisExecutor], a single thread. There is therefore at most one
 * decode in flight and no frame queue.
 */
class ScannerSession(
    private val id: Int,
    private val context: Context,
    private val textureRegistry: TextureRegistry,
    messenger: BinaryMessenger,
    configuration: ScannerConfiguration,
) : EventChannel.StreamHandler, LifecycleOwner {

    @Volatile private var configuration: ScannerConfiguration = configuration

    private val mainHandler = Handler(Looper.getMainLooper())
    private val analysisExecutor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "lbs-decode-$id").apply { priority = Thread.NORM_PRIORITY }
        }
    private val eventChannel =
        EventChannel(messenger, "$EVENT_CHANNEL_PREFIX/$id").also {
            it.setStreamHandler(this)
        }

    private val lifecycleRegistry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = lifecycleRegistry

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var preview: Preview? = null
    private var imageAnalysis: ImageAnalysis? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null

    private var eventSink: EventChannel.EventSink? = null

    // Written on the main thread, read by the analyzer thread.
    @Volatile private var released = false

    // --- analyzer-thread state -------------------------------------------
    private var decoder: NativeDecoder? = null
    private val analyzing = AtomicBoolean(false)
    private var lastAnalysisAt = 0L
    private var appliedRotation = Int.MIN_VALUE
    private var appliedCrop: ScanArea? = null
    private var appliedFormats = Int.MIN_VALUE
    @Volatile private var optionsDirty = true
    private val recentResults = LinkedHashMap<String, Long>()

    // --- shared state -----------------------------------------------------
    // The configuration is an immutable value replaced from the main thread and
    // read by the analyzer thread, so a volatile reference is all the
    // synchronisation these need.
    @Volatile private var analysisSize = Size(0, 0)
    @Volatile private var rotationDegrees = 0

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = Unit
        override fun onDisplayRemoved(displayId: Int) = Unit
        override fun onDisplayChanged(displayId: Int) = onDisplayRotationChanged()
    }

    init {
        lifecycleRegistry.currentState = Lifecycle.State.CREATED
    }

    // --- lifecycle --------------------------------------------------------

    /** Opens the camera. [onResult] is called on the main thread. */
    fun start(onResult: (Result<Map<String, Any?>>) -> Unit) {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (released) return@addListener
            try {
                cameraProvider = future.get()
                bind()
                onResult(Result.success(describe()))
            } catch (error: Throwable) {
                onResult(Result.failure(error))
            }
        }, ContextCompat.getMainExecutor(context))
    }

    private fun bind() {
        val provider = cameraProvider ?: throw IllegalStateException("No camera provider")
        provider.unbindAll()

        val entry = textureEntry ?: textureRegistry.createSurfaceTexture().also {
            textureEntry = it
        }

        val targetRotation = displayRotation()
        val resolutionSelector = ResolutionSelector.Builder()
            .setResolutionStrategy(
                ResolutionStrategy(
                    Size(configuration.resolution.width, configuration.resolution.height),
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                ),
            )
            .build()

        val preview = Preview.Builder()
            .setTargetRotation(targetRotation)
            .setResolutionSelector(resolutionSelector)
            .build()
        preview.setSurfaceProvider { request ->
            if (released) {
                request.willNotProvideSurface()
                return@setSurfaceProvider
            }
            val texture: SurfaceTexture = entry.surfaceTexture()
            texture.setDefaultBufferSize(request.resolution.width, request.resolution.height)
            val newSurface = Surface(texture)
            surface?.release()
            surface = newSurface
            request.provideSurface(newSurface, ContextCompat.getMainExecutor(context)) {
                newSurface.release()
                if (surface === newSurface) surface = null
            }
        }

        val analysis = ImageAnalysis.Builder()
            .setTargetRotation(targetRotation)
            .setResolutionSelector(resolutionSelector)
            // Latest frame wins: CameraX drops anything that arrives while we
            // are still decoding instead of building a backlog.
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
            .build()
        analysis.setAnalyzer(analysisExecutor, ::analyze)

        val selector = CameraSelector.Builder()
            .requireLensFacing(
                if (configuration.isFrontFacing) CameraSelector.LENS_FACING_FRONT
                else CameraSelector.LENS_FACING_BACK,
            )
            .build()

        lifecycleRegistry.currentState = Lifecycle.State.RESUMED
        camera = provider.bindToLifecycle(this, selector, preview, analysis)
        this.preview = preview
        this.imageAnalysis = analysis

        analyzing.set(true)
        optionsDirty = true

        if (configuration.torchEnabled && camera?.cameraInfo?.hasFlashUnit() == true) {
            camera?.cameraControl?.enableTorch(true)
        }

        displayManager().registerDisplayListener(displayListener, mainHandler)
        refreshGeometry()
    }

    /** Suspends analysis but keeps the camera and the preview alive. */
    fun pause() {
        analyzing.set(false)
    }

    fun resume() {
        analyzing.set(true)
        synchronized(recentResults) { recentResults.clear() }
    }

    /** Releases the camera, the texture and the native decoder. */
    fun release() {
        if (released) return
        released = true
        analyzing.set(false)
        runCatching { displayManager().unregisterDisplayListener(displayListener) }

        imageAnalysis?.clearAnalyzer()
        cameraProvider?.unbindAll()
        lifecycleRegistry.currentState = Lifecycle.State.DESTROYED
        camera = null
        preview = null
        imageAnalysis = null

        surface?.release()
        surface = null
        textureEntry?.release()
        textureEntry = null

        eventChannel.setStreamHandler(null)
        eventSink = null

        // The decoder belongs to the analyzer thread; free it there, then shut
        // the thread down so nothing can touch a dangling handle.
        analysisExecutor.execute {
            decoder?.close()
            decoder = null
        }
        analysisExecutor.shutdown()
    }

    // --- camera controls --------------------------------------------------

    fun hasTorch(): Boolean = camera?.cameraInfo?.hasFlashUnit() == true

    fun setTorch(enabled: Boolean) {
        val camera = camera ?: throw IllegalStateException("Camera is not running")
        if (!camera.cameraInfo.hasFlashUnit()) {
            throw UnsupportedOperationException("This camera has no torch")
        }
        camera.cameraControl.enableTorch(enabled)
    }

    fun setZoom(zoom: Float) {
        val camera = camera ?: throw IllegalStateException("Camera is not running")
        val state = camera.cameraInfo.zoomState.value
        val clamped = if (state == null) zoom
        else zoom.coerceIn(state.minZoomRatio, state.maxZoomRatio)
        camera.cameraControl.setZoomRatio(clamped)
    }

    /** [x] and [y] are fractions of the preview; null restores autofocus. */
    fun setFocusPoint(x: Float?, y: Float?) {
        val camera = camera ?: throw IllegalStateException("Camera is not running")
        if (x == null || y == null) {
            camera.cameraControl.cancelFocusAndMetering()
            return
        }
        val factory = SurfaceOrientedMeteringPointFactory(1f, 1f)
        val point = factory.createPoint(x.coerceIn(0f, 1f), y.coerceIn(0f, 1f))
        camera.cameraControl.startFocusAndMetering(
            FocusMeteringAction.Builder(point).build(),
        )
    }

    fun switchCamera(facing: String, onResult: (Result<Map<String, Any?>>) -> Unit) {
        configuration = configuration.copy(facing = facing, torchEnabled = false)
        try {
            bind()
            onResult(Result.success(describe()))
        } catch (error: Throwable) {
            onResult(Result.failure(error))
        }
    }

    fun setFormats(formats: Int) {
        configuration = configuration.copy(formats = formats)
        optionsDirty = true
    }

    fun setScanRegion(region: ScanArea?) {
        configuration = configuration.copy(scanRegion = region)
        optionsDirty = true
    }

    fun setDuplicateFilter(millis: Long) {
        configuration = configuration.copy(duplicateFilterMillis = millis)
        synchronized(recentResults) { recentResults.clear() }
    }

    // --- frame analysis ---------------------------------------------------

    private fun analyze(image: ImageProxy) {
        try {
            if (!analyzing.get() || released) return

            val now = SystemClock.elapsedRealtime()
            if (now - lastAnalysisAt < configuration.minAnalysisIntervalMillis) return
            lastAnalysisAt = now

            val decoder = decoder ?: NativeDecoder().also { this.decoder = it }
            if (!decoder.isValid) return

            val plane = image.planes[0]
            val rotation = image.imageInfo.rotationDegrees
            val rotatedWidth = if (rotation % 180 == 0) image.width else image.height
            val rotatedHeight = if (rotation % 180 == 0) image.height else image.width

            applyOptions(decoder, rotation, rotatedWidth, rotatedHeight)

            val barcodes = decoder.decode(
                plane.buffer,
                image.width,
                image.height,
                plane.rowStride,
                plane.pixelStride,
                configuration.includeRawBytes,
            ) ?: return

            val accepted = barcodes.filter { it.text.isNotEmpty() && accept(it, now) }
            if (accepted.isEmpty()) return

            val cropped = croppedSize(rotatedWidth, rotatedHeight)
            emitBarcodes(accepted, cropped)

            if (configuration.stopAfterFirstResult) {
                analyzing.set(false)
            }
        } catch (error: Throwable) {
            emitError("unknown", error.message ?: error.toString())
        } finally {
            // Closing here - and only here - is what keeps the pipeline at one
            // frame in flight.
            image.close()
        }
    }

    /** Pushes configuration into the native decoder, but only when it moved. */
    private fun applyOptions(
        decoder: NativeDecoder,
        rotation: Int,
        rotatedWidth: Int,
        rotatedHeight: Int,
    ) {
        val crop = configuration.scanRegion
        if (!optionsDirty &&
            rotation == appliedRotation &&
            configuration.formats == appliedFormats &&
            crop == appliedCrop
        ) {
            return
        }

        var cropLeft = 0
        var cropTop = 0
        var cropWidth = 0
        var cropHeight = 0
        if (crop != null && rotatedWidth > 0 && rotatedHeight > 0) {
            cropLeft = (crop.left * rotatedWidth).roundToInt().coerceIn(0, rotatedWidth - 1)
            cropTop = (crop.top * rotatedHeight).roundToInt().coerceIn(0, rotatedHeight - 1)
            cropWidth = max(1, (crop.width * rotatedWidth).roundToInt())
                .coerceAtMost(rotatedWidth - cropLeft)
            cropHeight = max(1, (crop.height * rotatedHeight).roundToInt())
                .coerceAtMost(rotatedHeight - cropTop)
        }

        decoder.setOptions(
            formats = configuration.formats,
            tryHarder = configuration.tryHarder,
            tryRotate = configuration.tryRotate,
            tryInvert = configuration.tryInvert,
            tryDownscale = configuration.tryDownscale,
            maxSymbols = configuration.maxSymbols,
            rotation = rotation,
            cropLeft = cropLeft,
            cropTop = cropTop,
            cropWidth = cropWidth,
            cropHeight = cropHeight,
        )

        appliedRotation = rotation
        appliedFormats = configuration.formats
        appliedCrop = crop
        optionsDirty = false

        if (rotatedWidth != analysisSize.width || rotatedHeight != analysisSize.height) {
            analysisSize = Size(rotatedWidth, rotatedHeight)
            mainHandler.post { emitPreview() }
        }
    }

    /** Duplicate suppression on `format + value`, as configured from Dart. */
    private fun accept(barcode: NativeBarcode, now: Long): Boolean {
        val window = configuration.duplicateFilterMillis
        if (window <= 0L) return true
        val key = "${barcode.format}:${barcode.text}"
        synchronized(recentResults) {
            val last = recentResults[key]
            if (last != null && now - last < window) return false
            recentResults[key] = now
            if (recentResults.size > MAX_TRACKED_RESULTS) {
                val iterator = recentResults.entries.iterator()
                while (iterator.hasNext() && recentResults.size > MAX_TRACKED_RESULTS / 2) {
                    iterator.next()
                    iterator.remove()
                }
            }
        }
        return true
    }

    private fun croppedSize(rotatedWidth: Int, rotatedHeight: Int): Size {
        val crop = configuration.scanRegion ?: return Size(rotatedWidth, rotatedHeight)
        return Size(
            max(1, (crop.width * rotatedWidth).roundToInt()),
            max(1, (crop.height * rotatedHeight).roundToInt()),
        )
    }

    // --- events -----------------------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun emitBarcodes(barcodes: List<NativeBarcode>, imageSize: Size) {
        val payload = mapOf(
            "type" to "barcodes",
            "imageWidth" to imageSize.width,
            "imageHeight" to imageSize.height,
            "barcodes" to barcodes.map { barcode ->
                mapOf(
                    "value" to barcode.text,
                    "format" to barcode.format,
                    "orientation" to barcode.orientation,
                    "corners" to barcode.corners.toList(),
                    "bytes" to barcode.bytes,
                )
            },
        )
        mainHandler.post { eventSink?.success(payload) }
    }

    private fun emitPreview() {
        if (released) return
        eventSink?.success(describe() + mapOf("type" to "preview"))
    }

    private fun emitError(code: String, message: String) {
        mainHandler.post { eventSink?.error(code, message, null) }
    }

    // --- geometry ---------------------------------------------------------

    private fun describe(): Map<String, Any?> {
        val info = preview?.resolutionInfo
        val previewSize = info?.resolution ?: Size(0, 0)
        val zoomState = camera?.cameraInfo?.zoomState?.value
        val analysis = if (analysisSize.width > 0) analysisSize else {
            imageAnalysis?.resolutionInfo?.let { rotatedSize(it.resolution, it.rotationDegrees) }
                ?: Size(0, 0)
        }
        return mapOf(
            "textureId" to (textureEntry?.id() ?: -1L),
            "previewWidth" to previewSize.width,
            "previewHeight" to previewSize.height,
            "analysisWidth" to analysis.width,
            "analysisHeight" to analysis.height,
            "rotationDegrees" to rotationDegrees,
            "facing" to configuration.facing,
            "isMirrored" to configuration.isFrontFacing,
            "hasTorch" to hasTorch(),
            "minZoom" to (zoomState?.minZoomRatio ?: 1f),
            "maxZoom" to (zoomState?.maxZoomRatio ?: 1f),
        )
    }

    private fun rotatedSize(size: Size, rotation: Int): Size =
        if (rotation % 180 == 0) size else Size(size.height, size.width)

    private fun refreshGeometry() {
        rotationDegrees = preview?.resolutionInfo?.rotationDegrees ?: 0
        imageAnalysis?.resolutionInfo?.let {
            analysisSize = rotatedSize(it.resolution, it.rotationDegrees)
        }
    }

    private fun onDisplayRotationChanged() {
        if (released) return
        val rotation = displayRotation()
        preview?.targetRotation = rotation
        imageAnalysis?.targetRotation = rotation
        refreshGeometry()
        optionsDirty = true
        emitPreview()
    }

    private fun displayManager(): DisplayManager =
        context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager

    private fun displayRotation(): Int =
        displayManager().getDisplay(android.view.Display.DEFAULT_DISPLAY)?.rotation
            ?: Surface.ROTATION_0

    companion object {
        const val EVENT_CHANNEL_PREFIX = "com.enver.lightweight_barcode_scanner/events"
        private const val MAX_TRACKED_RESULTS = 64
    }
}
