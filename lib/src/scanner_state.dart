/// Lifecycle of a [BarcodeScannerController].
///
/// ```text
/// idle ──start()──> initializing ──> running ──pause()──> paused
///                        │              │                   │
///                        │              └──stop()──> stopped ┘
///                        └──> error
/// ```
/// Any state can move to `disposed`, and nothing moves out of it.
enum ScannerState {
  /// Created but never started.
  idle,

  /// Opening the camera and building the decoder.
  initializing,

  /// Camera running, frames being analysed.
  running,

  /// Camera still open, analysis suspended. Cheap to [resume].
  paused,

  /// Camera released. [start] re-opens it.
  stopped,

  /// Something failed; see `controller.error`.
  error,

  /// Terminal. Every method throws from here on.
  disposed,
}

/// Why a scanner operation failed.
enum BarcodeScannerErrorCode {
  permissionDenied,
  permissionPermanentlyDenied,
  cameraUnavailable,
  cameraInitializationFailed,
  cameraInterrupted,
  decoderInitializationFailed,
  unsupportedOperation,
  invalidState,
  unknown;

  static BarcodeScannerErrorCode fromName(String? name) {
    for (final code in BarcodeScannerErrorCode.values) {
      if (code.name == name) return code;
    }
    return BarcodeScannerErrorCode.unknown;
  }
}

/// Thrown by the controller and reported through `controller.error`.
class BarcodeScannerException implements Exception {
  const BarcodeScannerException(this.code, this.message, {this.details});

  final BarcodeScannerErrorCode code;
  final String message;
  final Object? details;

  /// Whether asking the user again could plausibly help.
  bool get isRecoverable =>
      code != BarcodeScannerErrorCode.permissionPermanentlyDenied &&
      code != BarcodeScannerErrorCode.cameraUnavailable;

  @override
  String toString() => 'BarcodeScannerException(${code.name}): $message';
}

/// Result of a camera permission request.
enum CameraPermissionStatus {
  granted,
  denied,

  /// The user chose "don't ask again" (Android) or denied it in Settings
  /// (iOS). Only a trip to the system settings can change this.
  permanentlyDenied,

  /// Blocked by device policy or parental controls.
  restricted;

  static CameraPermissionStatus fromName(String? name) {
    for (final status in CameraPermissionStatus.values) {
      if (status.name == name) return status;
    }
    return CameraPermissionStatus.denied;
  }
}
