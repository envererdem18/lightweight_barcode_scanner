import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'barcode_format.dart';
import 'barcode_result.dart';
import 'platform/scanner_channel.dart';
import 'platform/scanner_preview.dart';
import 'scanner_options.dart';
import 'scanner_state.dart';

/// Owns one camera session and the native decoder attached to it.
///
/// The controller is a [ChangeNotifier]: it notifies on state, preview, torch
/// and zoom changes so a widget can rebuild. Decoded barcodes arrive on the
/// [barcodes] stream instead, because they are events rather than state.
///
/// Camera frames never reach Dart. The native side analyses them and sends
/// only the small result records over the event channel.
class BarcodeScannerController extends ChangeNotifier {
  BarcodeScannerController({
    Set<BarcodeFormat> formats = const {},
    ScanMode scanMode = ScanMode.continuous,
    CameraFacing facing = CameraFacing.back,
    ScanResolution resolution = ScanResolution.medium,
    DecoderProfile profile = DecoderProfile.balanced,
    Duration duplicateFilterDuration = const Duration(milliseconds: 750),
    int detectionsPerSecond = 12,
    Rect? scanRegion,
    bool includeRawBytes = false,
    bool torchEnabled = false,
    AutoZoom autoZoom = AutoZoom.enabled,
    double initialZoom = 1.4,
    @visibleForTesting ScannerChannel? channel,
  }) : _options = ScannerOptions(
         formats: formats,
         scanMode: scanMode,
         facing: facing,
         resolution: resolution,
         profile: profile,
         duplicateFilterDuration: duplicateFilterDuration,
         detectionsPerSecond: detectionsPerSecond,
         scanRegion: scanRegion,
         includeRawBytes: includeRawBytes,
         torchEnabled: torchEnabled,
         autoZoom: autoZoom,
         initialZoom: initialZoom,
       ),
       _channel = channel ?? ScannerChannel();

  final ScannerChannel _channel;
  final StreamController<BarcodeCapture> _captures =
      StreamController<BarcodeCapture>.broadcast();

  ScannerOptions _options;
  ScannerState _state = ScannerState.idle;
  BarcodeScannerException? _error;
  ScannerPreview? _preview;
  int? _sessionId;
  StreamSubscription<Map<Object?, Object?>>? _events;
  bool _torchEnabled = false;
  double _zoom = 1;
  // Guards against overlapping start()/stop() calls, which are easy to trigger
  // from lifecycle callbacks.
  Future<void>? _pendingTransition;

  // --- auto zoom ---------------------------------------------------------
  //
  // A barcode that will not decode is usually a barcode the lens cannot focus
  // on: to fill the frame at 1x the phone has to come closer than the minimum
  // focus distance, and the symbol grows and blurs at the same time. Zooming
  // buys the same framing from a focusable distance. See ScannerOptions.autoZoom.
  //
  // The ramp is deliberately slow and small. It only starts after a stretch of
  // silence, so a scan that is working never sees it, and it stops at an
  // absolute 2x - not 2x whatever it started from - because beyond roughly that
  // point a phone is upscaling pixels it never captured: all cost in field of
  // view, no gain in detail. With the default resting point that makes the
  // whole range 1.4x to 2x, small enough that handing the framing back is not
  // a jolt.
  Timer? _autoZoomTimer;
  // Counted in ticks rather than wall-clock time: the ramp only ever moves on
  // its own timer, so there is nothing a clock would tell it that the tick
  // count does not, and it keeps the behaviour deterministic under test.
  int _idleTicks = 0;
  double _autoZoomBase = 1;
  bool _autoZoomSuspended = false;

  static const Duration _autoZoomIdleDelay = Duration(milliseconds: 1200);
  static const Duration _autoZoomStepInterval = Duration(milliseconds: 400);
  static const double _autoZoomStepFactor = 1.2;
  static const double _autoZoomCeiling = 2;

  static int get _autoZoomIdleTicks =>
      _autoZoomIdleDelay.inMilliseconds ~/ _autoZoomStepInterval.inMilliseconds;

  ScannerOptions get options => _options;
  ScannerState get state => _state;
  BarcodeScannerException? get error => _error;

  /// Null until the camera is running.
  ScannerPreview? get preview => _preview;

  bool get isRunning => _state == ScannerState.running;
  bool get torchEnabled => _torchEnabled;
  double get zoom => _zoom;

  /// One event per analysed frame that produced at least one barcode.
  Stream<BarcodeCapture> get captures => _captures.stream;

  /// Flattened convenience view of [captures].
  Stream<BarcodeResult> get barcodes =>
      _captures.stream.expand((capture) => capture.barcodes);

  /// Asks for camera permission without starting the camera.
  Future<CameraPermissionStatus> requestPermission() {
    _assertUsable();
    return _channel.requestPermission();
  }

  /// Opens the camera and starts analysing frames.
  ///
  /// Safe to call when already running: it returns without doing anything.
  Future<void> start() {
    _assertUsable();
    if (_state == ScannerState.running || _state == ScannerState.initializing) {
      return _pendingTransition ?? Future<void>.value();
    }
    return _serialize(_start);
  }

  Future<void> _start() async {
    _setState(ScannerState.initializing, error: null);
    try {
      final permission = await _channel.requestPermission();
      if (permission != CameraPermissionStatus.granted) {
        throw BarcodeScannerException(
          permission == CameraPermissionStatus.permanentlyDenied ||
                  permission == CameraPermissionStatus.restricted
              ? BarcodeScannerErrorCode.permissionPermanentlyDenied
              : BarcodeScannerErrorCode.permissionDenied,
          'Camera permission was not granted.',
        );
      }

      final sessionId = await _channel.create(_options);
      _sessionId = sessionId;
      _events = _channel.events(sessionId).listen(
        _onEvent,
        onError: (Object error, StackTrace stackTrace) =>
            _fail(_asException(error)),
      );

      final preview = await _channel.start(sessionId);
      if (_state == ScannerState.disposed) {
        await _channel.dispose(sessionId);
        return;
      }
      _preview = preview;
      _torchEnabled = _options.torchEnabled;
      _zoom = 1;
      await _applyInitialZoom();
      _resetAutoZoom(startTimer: true);
      _setState(ScannerState.running, error: null);
    } on BarcodeScannerException catch (exception) {
      await _releaseSession();
      _fail(exception);
      rethrow;
    } catch (error) {
      await _releaseSession();
      final exception = _asException(error);
      _fail(exception);
      throw exception;
    }
  }

  /// Releases the camera and the preview texture.
  ///
  /// Use [pause] instead when you only want to suspend detection, for example
  /// while a result dialog is open.
  Future<void> stop() {
    _assertUsable();
    if (_state == ScannerState.idle || _state == ScannerState.stopped) {
      return Future<void>.value();
    }
    return _serialize(() async {
      await _releaseSession();
      _preview = null;
      _torchEnabled = false;
      _stopAutoZoom();
      _setState(ScannerState.stopped, error: null);
    });
  }

  /// Stops analysing frames while keeping the camera and preview alive.
  Future<void> pause() async {
    _assertUsable();
    final sessionId = _sessionId;
    if (_state != ScannerState.running || sessionId == null) return;
    await _channel.pause(sessionId);
    _stopAutoZoom();
    _setState(ScannerState.paused);
  }

  /// Resumes analysis after [pause].
  Future<void> resume() async {
    _assertUsable();
    final sessionId = _sessionId;
    if (_state != ScannerState.paused || sessionId == null) return;
    await _channel.resume(sessionId);
    _resetAutoZoom(startTimer: true);
    _setState(ScannerState.running);
  }

  Future<void> setTorch(bool enabled) async {
    final sessionId = _requireSession('setTorch');
    if (_preview?.hasTorch != true) {
      throw const BarcodeScannerException(
        BarcodeScannerErrorCode.unsupportedOperation,
        'This camera has no torch.',
      );
    }
    await _channel.setTorch(sessionId, enabled: enabled);
    _torchEnabled = enabled;
    _options = _options.copyWith(torchEnabled: enabled);
    notifyListeners();
  }

  Future<void> toggleTorch() => setTorch(!_torchEnabled);

  /// Sets the zoom ratio, clamped to what the camera reports.
  ///
  /// This is the app taking over, so it also switches [ScannerOptions.autoZoom]
  /// off for the rest of the session: a scanner that fought the user's own
  /// zoom would be worse than one that never zoomed at all.
  Future<void> setZoom(double zoom) async {
    final sessionId = _requireSession('setZoom');
    _autoZoomSuspended = true;
    _autoZoomTimer?.cancel();
    _autoZoomTimer = null;
    final preview = _preview;
    final clamped = preview == null
        ? zoom
        : zoom.clamp(preview.minZoom, preview.maxZoom).toDouble();
    await _channel.setZoom(sessionId, clamped);
    _zoom = clamped;
    notifyListeners();
  }

  /// Focuses on a point given in normalised preview coordinates (0..1).
  /// Passing null returns the camera to continuous autofocus.
  Future<void> setFocusPoint(Offset? point) async {
    final sessionId = _requireSession('setFocusPoint');
    await _channel.setFocusPoint(sessionId, point);
  }

  /// Switches between the front and back camera, restarting the session.
  Future<void> switchCamera() async {
    final sessionId = _requireSession('switchCamera');
    final facing = _options.facing == CameraFacing.back
        ? CameraFacing.front
        : CameraFacing.back;
    final preview = await _channel.switchCamera(sessionId, facing);
    _options = _options.copyWith(facing: facing);
    _preview = preview;
    _torchEnabled = false;
    _zoom = 1;
    // A different camera reports a different zoom range, so the resting point
    // has to be re-established against it.
    await _applyInitialZoom();
    _resetAutoZoom(startTimer: _state == ScannerState.running);
    notifyListeners();
  }

  /// Narrows or widens the symbologies the decoder attempts, without
  /// restarting the camera.
  Future<void> setFormats(Set<BarcodeFormat> formats) async {
    final sessionId = _requireSession('setFormats');
    await _channel.setFormats(sessionId, formats);
    _options = _options.copyWith(formats: formats);
    notifyListeners();
  }

  /// Restricts decoding to a fraction of the frame (0..1), or clears it.
  Future<void> setScanRegion(Rect? region) async {
    final sessionId = _requireSession('setScanRegion');
    assert(
      region == null ||
          (region.left >= 0 &&
              region.top >= 0 &&
              region.right <= 1 &&
              region.bottom <= 1),
      'scanRegion must be expressed as fractions of the frame (0..1)',
    );
    await _channel.setScanRegion(sessionId, region);
    _options = _options.copyWith(
      scanRegion: region,
      clearScanRegion: region == null,
    );
    notifyListeners();
  }

  /// Changes how long a repeated `format + value` stays suppressed.
  Future<void> setDuplicateFilterDuration(Duration duration) async {
    final sessionId = _requireSession('setDuplicateFilterDuration');
    await _channel.setDuplicateFilter(sessionId, duration);
    _options = _options.copyWith(duplicateFilterDuration: duration);
  }

  @override
  void dispose() {
    if (_state == ScannerState.disposed) return;
    _state = ScannerState.disposed;
    // Fire and forget: dispose() cannot be async, but the native session must
    // be released even if nobody awaits it.
    _stopAutoZoom();
    unawaited(_releaseSession());
    unawaited(_captures.close());
    super.dispose();
  }

  // --- internals ---------------------------------------------------------

  /// True when the session is in a state where the ramp may run at all: the
  /// caller asked for it, the app has not taken the zoom over, and the camera
  /// actually has zoom to give.
  bool get _autoZoomAvailable {
    final preview = _preview;
    return _options.autoZoom.appliesTo(defaultTargetPlatform) &&
        !_autoZoomSuspended &&
        preview != null &&
        preview.maxZoom > preview.minZoom;
  }

  /// Moves the camera to [ScannerOptions.initialZoom] without going through the
  /// public [setZoom], which would read as the app taking over and switch the
  /// ramp off.
  Future<void> _applyInitialZoom() async {
    final preview = _preview;
    final sessionId = _sessionId;
    if (preview == null || sessionId == null) return;
    final target = _options.initialZoom
        .clamp(preview.minZoom, preview.maxZoom)
        .toDouble();
    if ((target - _zoom).abs() < 0.01) return;
    try {
      await _channel.setZoom(sessionId, target);
      _zoom = target;
    } on Object {
      // A camera that will not take the ratio just stays where it is.
    }
  }

  void _resetAutoZoom({required bool startTimer}) {
    _autoZoomTimer?.cancel();
    _autoZoomTimer = null;
    _autoZoomBase = _zoom;
    _idleTicks = 0;
    if (!startTimer || !_autoZoomAvailable) return;
    _autoZoomTimer = Timer.periodic(_autoZoomStepInterval, (_) => _stepAutoZoom());
  }

  void _stopAutoZoom() {
    _autoZoomTimer?.cancel();
    _autoZoomTimer = null;
  }

  /// A read means the current framing works: give the field of view back.
  void _onDecodeSucceeded() {
    _idleTicks = 0;
    if (!_autoZoomAvailable || _zoom == _autoZoomBase) return;
    unawaited(_applyAutoZoom(_autoZoomBase));
  }

  void _stepAutoZoom() {
    if (_state != ScannerState.running || !_autoZoomAvailable) return;
    if (++_idleTicks < _autoZoomIdleTicks) return;

    final preview = _preview!;
    final ceiling = _autoZoomCeiling;
    final target = (_zoom * _autoZoomStepFactor).clamp(
      preview.minZoom,
      [ceiling, preview.maxZoom].reduce((a, b) => a < b ? a : b),
    );
    // Within a hair of the ceiling: stop asking the camera for the same ratio
    // every tick. The ramp stays where it is until something decodes.
    if (target - _zoom < 0.01) return;
    unawaited(_applyAutoZoom(target));
  }

  Future<void> _applyAutoZoom(double zoom) async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      await _channel.setZoom(sessionId, zoom);
      _zoom = zoom;
      notifyListeners();
    } on Object {
      // A camera that refuses a zoom ratio is not an error worth surfacing:
      // the scan is still running, it just does not get the extra reach.
      _autoZoomSuspended = true;
      _stopAutoZoom();
    }
  }

  void _onEvent(Map<Object?, Object?> event) {
    switch (event['type']) {
      case 'barcodes':
        final size = Size(
          (event['imageWidth'] as num?)?.toDouble() ?? 0,
          (event['imageHeight'] as num?)?.toDouble() ?? 0,
        );
        final raw = event['barcodes'];
        if (raw is! List || raw.isEmpty) return;
        final results = <BarcodeResult>[
          for (final item in raw)
            BarcodeResult.fromMap(item as Map<Object?, Object?>, size),
        ];
        _captures.add(BarcodeCapture(barcodes: results, imageSize: size));
        _onDecodeSucceeded();
        if (_options.scanMode == ScanMode.single) {
          // The native side already stopped analysing; mirror that here so the
          // controller does not claim to be running.
          _setState(ScannerState.paused);
        }
      case 'preview':
        _preview = ScannerPreview.fromMap(event);
        notifyListeners();
      case 'state':
        final name = event['state'];
        for (final value in ScannerState.values) {
          if (value.name == name && value != ScannerState.disposed) {
            _setState(value);
            break;
          }
        }
      case 'error':
        _fail(
          BarcodeScannerException(
            BarcodeScannerErrorCode.fromName(event['code'] as String?),
            (event['message'] as String?) ?? 'The camera reported an error.',
          ),
        );
    }
  }

  Future<void> _releaseSession() async {
    final sessionId = _sessionId;
    _sessionId = null;
    final events = _events;
    _events = null;
    // Not awaited on purpose: cancelling an event-channel subscription is
    // local bookkeeping, and awaiting it stalls under the fake clock used by
    // widget tests. The native session is torn down below either way.
    unawaited(events?.cancel() ?? Future<void>.value());
    if (sessionId == null) return;
    try {
      await _channel.dispose(sessionId);
    } on BarcodeScannerException {
      // The session is gone either way; nothing useful to do here.
    }
  }

  Future<void> _serialize(Future<void> Function() action) {
    final previous = _pendingTransition ?? Future<void>.value();
    final next = previous
        .catchError((Object _) {})
        .then((_) => _state == ScannerState.disposed
            ? Future<void>.value()
            : action());
    _pendingTransition = next.catchError((Object _) {});
    return next;
  }

  void _setState(ScannerState state, {BarcodeScannerException? error}) {
    if (_state == ScannerState.disposed) return;
    if (_state == state && error == _error) return;
    _state = state;
    if (error != null || state != ScannerState.error) _error = error;
    notifyListeners();
  }

  void _fail(BarcodeScannerException exception) {
    _setState(ScannerState.error, error: exception);
  }

  int _requireSession(String operation) {
    _assertUsable();
    final sessionId = _sessionId;
    if (sessionId == null) {
      throw BarcodeScannerException(
        BarcodeScannerErrorCode.invalidState,
        'Call start() before $operation().',
      );
    }
    return sessionId;
  }

  void _assertUsable() {
    if (_state == ScannerState.disposed) {
      throw const BarcodeScannerException(
        BarcodeScannerErrorCode.invalidState,
        'This BarcodeScannerController has been disposed.',
      );
    }
  }

  BarcodeScannerException _asException(Object error) {
    if (error is BarcodeScannerException) return error;
    return BarcodeScannerException(
      BarcodeScannerErrorCode.unknown,
      error.toString(),
      details: error,
    );
  }
}
