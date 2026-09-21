package com.enver.lightweight_barcode_scanner

/** Analysis resolution, as a plain pair so this file stays framework-free. */
data class AnalysisResolution(val width: Int, val height: Int)

/** Region of interest as fractions (0..1) of the upright frame. */
data class ScanArea(
    val left: Float,
    val top: Float,
    val width: Float,
    val height: Float,
)

/**
 * Scanner settings as they arrive from Dart.
 *
 * Deliberately free of Android types: this is the mirror image of
 * `ScannerOptions.toMap()` on the Dart side and the place where the two are
 * most likely to drift apart, so it has to be unit-testable on the JVM.
 */
data class ScannerConfiguration(
    val formats: Int,
    val scanMode: String,
    val facing: String,
    val resolution: AnalysisResolution,
    val profile: String,
    val duplicateFilterMillis: Long,
    val detectionsPerSecond: Int,
    val includeRawBytes: Boolean,
    val torchEnabled: Boolean,
    val scanRegion: ScanArea?,
) {
    val isFrontFacing: Boolean get() = facing == "front"

    val maxSymbols: Int get() = if (scanMode == "multiple") 16 else 1

    val stopAfterFirstResult: Boolean get() = scanMode == "single"

    /** Minimum gap between decode attempts. Surplus frames are dropped. */
    val minAnalysisIntervalMillis: Long get() = 1000L / detectionsPerSecond

    val tryHarder: Boolean get() = profile != "fast"
    val tryRotate: Boolean get() = profile != "fast"
    val tryInvert: Boolean get() = profile == "thorough"
    val tryDownscale: Boolean get() = profile != "fast"

    companion object {
        fun fromMap(arguments: Map<*, *>): ScannerConfiguration = ScannerConfiguration(
            formats = (arguments["formats"] as? Number)?.toInt() ?: 0,
            scanMode = arguments["scanMode"] as? String ?: "continuous",
            facing = arguments["facing"] as? String ?: "back",
            resolution = resolutionFor(arguments["resolution"] as? String),
            profile = arguments["profile"] as? String ?: "balanced",
            duplicateFilterMillis =
                (arguments["duplicateFilterMillis"] as? Number)?.toLong() ?: 750L,
            detectionsPerSecond =
                ((arguments["detectionsPerSecond"] as? Number)?.toInt() ?: 12)
                    .coerceIn(1, 60),
            includeRawBytes = arguments["includeRawBytes"] as? Boolean ?: false,
            torchEnabled = arguments["torchEnabled"] as? Boolean ?: false,
            scanRegion = scanAreaFrom(arguments["scanRegion"]),
        )

        /** The wire format is `[left, top, width, height]`, all fractions. */
        fun scanAreaFrom(value: Any?): ScanArea? {
            val values = value as? List<*> ?: return null
            if (values.size < 4) return null
            return ScanArea(
                (values[0] as Number).toFloat(),
                (values[1] as Number).toFloat(),
                (values[2] as Number).toFloat(),
                (values[3] as Number).toFloat(),
            )
        }

        private fun resolutionFor(name: String?): AnalysisResolution = when (name) {
            "low" -> AnalysisResolution(640, 480)
            "high" -> AnalysisResolution(1920, 1080)
            else -> AnalysisResolution(1280, 720)
        }
    }
}
