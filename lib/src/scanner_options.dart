import 'dart:ui';

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
  }) : assert(
         detectionsPerSecond > 0 && detectionsPerSecond <= 60,
         'detectionsPerSecond must be between 1 and 60',
       );

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
    );
  }

  /// The wire format shared by the Android and iOS implementations.
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
