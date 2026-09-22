import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'barcode_format.dart';

/// What the scanner does after a successful detection.
enum ScanMode {
  /// Keep scanning. Duplicate suppression keeps the stream readable.
  continuous,

  /// Stop the camera after the first accepted barcode.
  single,

  /// Report every barcode found in a frame instead of just the first one.
  /// Costs measurably more CPU, so it is opt-in.
  multiple,
}

/// Which camera to open.
enum CameraFacing { back, front }

/// Analysis resolution.
///
/// This is the resolution the *decoder* sees. A higher value helps with small
/// or distant symbols and costs CPU; it does not have to match the preview.
enum ScanResolution {
  /// 640x480. Fastest, fine for a symbol that fills a good part of the frame.
  low,

  /// 1280x720. The default: reliable for retail barcodes at arm's length.
  medium,

  /// 1920x1080. For small or dense symbols, at roughly twice the CPU cost.
  high,
}

/// How much work the decoder is allowed to do per frame.
///
/// These map onto ZXing fallbacks internally; they are expressed as intent so
/// the public API does not leak decoder internals.
enum DecoderProfile {
  /// No fallbacks. Lowest latency, expects an upright, well-lit symbol.
  fast,

  /// Rotation and downscale fallbacks. The default.
  balanced,

  /// Everything, including inverted (light-on-dark) symbols. Noticeably more
  /// CPU per frame - prefer it for still images or a "having trouble?" mode.
  thorough,
}

/// Which platforms the auto zoom ramp runs on.
///
/// The ramp is a workaround for a lens that cannot focus as close as a barcode
/// needs it to, and how much that bites depends on the hardware: a camera with
/// a short minimum focus distance barely needs it, and on such a device the
/// narrower field of view is a cost with no return. So it is worth being able
/// to keep it on the platform that needs it and off the one that does not.
enum AutoZoom {
  /// Ramp on both platforms.
  enabled,

  /// Ramp on iOS only; leave Android at [ScannerOptions.initialZoom].
  enabledIosOnly,

  /// Ramp on Android only; leave iOS at [ScannerOptions.initialZoom].
  enabledAndroidOnly,

  /// Never ramp. The zoom is whatever the app sets.
  disabled;

  /// Whether the ramp should run on [platform].
  ///
  /// [ScannerOptions.initialZoom] is unaffected: it is where the camera opens
  /// on every platform, ramp or no ramp.
  bool appliesTo(TargetPlatform platform) => switch (this) {
    AutoZoom.enabled => true,
    AutoZoom.enabledIosOnly => platform == TargetPlatform.iOS,
    AutoZoom.enabledAndroidOnly => platform == TargetPlatform.android,
    AutoZoom.disabled => false,
  };
}

/// Immutable scanner configuration.
class ScannerOptions {
  const ScannerOptions({
    this.formats = const {},
    this.scanMode = ScanMode.continuous,
    this.facing = CameraFacing.back,
    this.resolution = ScanResolution.medium,
    this.profile = DecoderProfile.balanced,
    this.duplicateFilterDuration = const Duration(milliseconds: 750),
    this.detectionsPerSecond = 12,
    this.scanRegion,
    this.includeRawBytes = false,
    this.torchEnabled = false,
    this.autoZoom = AutoZoom.enabled,
    this.initialZoom = 1.4,
  }) : assert(
         detectionsPerSecond > 0 && detectionsPerSecond <= 60,
         'detectionsPerSecond must be between 1 and 60',
       ),
       assert(initialZoom > 0, 'initialZoom must be greater than 0');

  /// Symbologies to look for. Empty means every supported format, which is
  /// slower - narrow it down whenever you can.
  final Set<BarcodeFormat> formats;

  final ScanMode scanMode;
  final CameraFacing facing;
  final ScanResolution resolution;
  final DecoderProfile profile;

  /// How long the same `format + value` is suppressed after being reported.
  /// [Duration.zero] disables suppression.
  final Duration duplicateFilterDuration;

  /// Upper bound on decode attempts per second. The camera keeps running at
  /// its own frame rate; surplus frames are dropped, never queued.
  final int detectionsPerSecond;

  /// Region of interest as a fraction of the analysed image (0..1), in the
  /// upright preview orientation. Null scans the whole frame.
  final Rect? scanRegion;

  /// Include the raw payload bytes in results.
  final bool includeRawBytes;

  /// Turn the torch on as soon as the camera starts.
  final bool torchEnabled;

  /// Zoom in by itself while nothing is decoding, then drop back on the first
  /// read. On for both platforms by default; see [AutoZoom] to limit it to one.
  ///
  /// Linear symbologies are limited by *defocus*, not by resolution: adjacent
  /// narrow bars blur into each other long before the frame runs out of
  /// pixels. Measured against the host fixtures, how much blur a symbol
  /// survives scales with how much of the frame it covers - an EAN-13 rendered
  /// at 2 px per module tolerates about 1 px of blur, the same symbol at 6 px
  /// per module tolerates 4.
  ///
  /// The trap is that at 1x the only way to make the symbol fill the frame is
  /// to move the phone closer, and past the lens's minimum focus distance it
  /// can no longer focus at all - so the symbol gets bigger and blurrier at the
  /// same time. Zooming buys the same coverage from a distance the lens can
  /// still focus at. QR codes rarely need it: error correction and wider
  /// modules make them far more blur-tolerant, which is why a scanner can feel
  /// flawless on QR and unreliable on a barcode in the same session.
  ///
  /// Calling [BarcodeScannerController.setZoom] hands control back to the app
  /// and switches this off for the rest of the session.
  final AutoZoom autoZoom;

  /// Zoom ratio the camera opens at, clamped to what it reports. Defaults to
  /// 1.4, and is also where [autoZoom] returns to after a read.
  ///
  /// 1.0 is a poor resting point for a scanner. It is the widest field of view,
  /// so it is the ratio that forces the user closest to the symbol, and it is
  /// the far end of a visible jump every time auto zoom hands the framing back.
  /// Starting slightly tight costs a little of the frame and removes both.
  ///
  /// Pass 1 to get the camera's full field of view back.
  final double initialZoom;

  ScannerOptions copyWith({
    Set<BarcodeFormat>? formats,
    ScanMode? scanMode,
    CameraFacing? facing,
    ScanResolution? resolution,
    DecoderProfile? profile,
    Duration? duplicateFilterDuration,
    int? detectionsPerSecond,
    Rect? scanRegion,
    bool clearScanRegion = false,
    bool? includeRawBytes,
    bool? torchEnabled,
    AutoZoom? autoZoom,
    double? initialZoom,
  }) {
    return ScannerOptions(
      formats: formats ?? this.formats,
      scanMode: scanMode ?? this.scanMode,
      facing: facing ?? this.facing,
      resolution: resolution ?? this.resolution,
      profile: profile ?? this.profile,
      duplicateFilterDuration:
          duplicateFilterDuration ?? this.duplicateFilterDuration,
      detectionsPerSecond: detectionsPerSecond ?? this.detectionsPerSecond,
      scanRegion: clearScanRegion ? null : (scanRegion ?? this.scanRegion),
      includeRawBytes: includeRawBytes ?? this.includeRawBytes,
      torchEnabled: torchEnabled ?? this.torchEnabled,
      autoZoom: autoZoom ?? this.autoZoom,
      initialZoom: initialZoom ?? this.initialZoom,
    );
  }

  /// The wire format shared by the Android and iOS implementations.
  ///
  /// [autoZoom] and [initialZoom] are deliberately absent: both are driven from
  /// Dart through the existing `setZoom` call, so neither platform needs its
  /// own copy of the logic.
  Map<String, Object?> toMap() {
    final region = scanRegion;
    return <String, Object?>{
      'formats': BarcodeFormat.toMask(formats),
      'scanMode': scanMode.name,
      'facing': facing.name,
      'resolution': resolution.name,
      'profile': profile.name,
      'duplicateFilterMillis': duplicateFilterDuration.inMilliseconds,
      'detectionsPerSecond': detectionsPerSecond,
      'includeRawBytes': includeRawBytes,
      'torchEnabled': torchEnabled,
      if (region != null)
        'scanRegion': <double>[
          region.left,
          region.top,
          region.width,
          region.height,
        ],
    };
  }
}
