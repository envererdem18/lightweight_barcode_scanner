import 'dart:ui';

import '../scanner_options.dart';

/// What the native side tells us about the running camera.
class ScannerPreview {
  const ScannerPreview({
    required this.textureId,
    required this.previewSize,
    required this.analysisSize,
    required this.rotationDegrees,
    required this.facing,
    required this.isMirrored,
    required this.hasTorch,
    required this.minZoom,
    required this.maxZoom,
  });

  /// Flutter texture backing the preview. Frames go camera -> texture on the
  /// GPU; they never pass through Dart.
  final int textureId;

  /// Native size of the texture, before [rotationDegrees] is applied.
  final Size previewSize;

  /// Size of the buffer the decoder analyses. Barcode corner points are in
  /// this space.
  final Size analysisSize;

  /// Clockwise rotation, in degrees, that makes the texture upright.
  final int rotationDegrees;

  final CameraFacing facing;

  /// Front cameras are mirrored for preview.
  final bool isMirrored;

  final bool hasTorch;
  final double minZoom;
  final double maxZoom;

  /// Preview size after [rotationDegrees].
  Size get orientedPreviewSize => rotationDegrees % 180 == 0
      ? previewSize
      : Size(previewSize.height, previewSize.width);

  double get aspectRatio {
    final size = orientedPreviewSize;
    if (size.height == 0) return 1;
    return size.width / size.height;
  }

  ScannerPreview copyWith({int? textureId}) => ScannerPreview(
    textureId: textureId ?? this.textureId,
    previewSize: previewSize,
    analysisSize: analysisSize,
    rotationDegrees: rotationDegrees,
    facing: facing,
    isMirrored: isMirrored,
    hasTorch: hasTorch,
    minZoom: minZoom,
    maxZoom: maxZoom,
  );

  static ScannerPreview fromMap(Map<Object?, Object?> map) {
    double number(Object? value, [double fallback = 0]) =>
        value is num ? value.toDouble() : fallback;
    return ScannerPreview(
      textureId: (map['textureId']! as num).toInt(),
      previewSize: Size(number(map['previewWidth']), number(map['previewHeight'])),
      analysisSize: Size(
        number(map['analysisWidth']),
        number(map['analysisHeight']),
      ),
      rotationDegrees: (map['rotationDegrees'] as num?)?.toInt() ?? 0,
      facing: map['facing'] == 'front' ? CameraFacing.front : CameraFacing.back,
      isMirrored: map['isMirrored'] == true,
      hasTorch: map['hasTorch'] == true,
      minZoom: number(map['minZoom'], 1),
      maxZoom: number(map['maxZoom'], 1),
    );
  }
}
