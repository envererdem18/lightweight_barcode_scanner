package com.enver.lightweight_barcode_scanner

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Guards the wire format against drift from `ScannerOptions.toMap()` in Dart.
 * Every key here has a counterpart in test/scanner_options_test.dart.
 */
internal class ScannerConfigurationTest {

    @Test
    fun `reads the full wire format`() {
        val configuration = ScannerConfiguration.fromMap(
            mapOf(
                "formats" to 0b11000,
                "scanMode" to "single",
                "facing" to "front",
                "resolution" to "high",
                "profile" to "thorough",
                "duplicateFilterMillis" to 500,
                "detectionsPerSecond" to 8,
                "includeRawBytes" to true,
                "torchEnabled" to true,
                "scanRegion" to listOf(0.1, 0.2, 0.5, 0.25),
            ),
        )

        assertEquals(0b11000, configuration.formats)
        assertEquals(AnalysisResolution(1920, 1080), configuration.resolution)
        assertTrue(configuration.isFrontFacing)
        assertTrue(configuration.stopAfterFirstResult)
        assertTrue(configuration.includeRawBytes)
        assertTrue(configuration.torchEnabled)
        assertEquals(500L, configuration.duplicateFilterMillis)
        assertEquals(125L, configuration.minAnalysisIntervalMillis)

        val region = requireNotNull(configuration.scanRegion)
        assertEquals(0.1f, region.left)
        assertEquals(0.2f, region.top)
        assertEquals(0.5f, region.width)
        assertEquals(0.25f, region.height)
    }

    @Test
    fun `falls back to safe defaults`() {
        val configuration = ScannerConfiguration.fromMap(emptyMap<String, Any>())

        assertEquals(0, configuration.formats)
        assertEquals(AnalysisResolution(1280, 720), configuration.resolution)
        assertEquals("continuous", configuration.scanMode)
        assertEquals(1, configuration.maxSymbols)
        assertEquals(12, configuration.detectionsPerSecond)
        assertNull(configuration.scanRegion)
    }

    @Test
    fun `clamps an out of range detection rate`() {
        assertEquals(
            1,
            ScannerConfiguration.fromMap(mapOf("detectionsPerSecond" to 0))
                .detectionsPerSecond,
        )
        assertEquals(
            60,
            ScannerConfiguration.fromMap(mapOf("detectionsPerSecond" to 900))
                .detectionsPerSecond,
        )
    }

    @Test
    fun `decoder fallbacks follow the profile`() {
        val fast = ScannerConfiguration.fromMap(mapOf("profile" to "fast"))
        assertEquals(false, fast.tryHarder)
        assertEquals(false, fast.tryRotate)
        assertEquals(false, fast.tryInvert)

        val balanced = ScannerConfiguration.fromMap(mapOf("profile" to "balanced"))
        assertEquals(true, balanced.tryRotate)
        assertEquals(false, balanced.tryInvert)

        val thorough = ScannerConfiguration.fromMap(mapOf("profile" to "thorough"))
        assertEquals(true, thorough.tryInvert)
    }

    @Test
    fun `multiple mode raises the symbol cap`() {
        val configuration = ScannerConfiguration.fromMap(mapOf("scanMode" to "multiple"))
        assertTrue(configuration.maxSymbols > 1)
    }
}
