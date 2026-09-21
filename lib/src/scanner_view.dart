import 'dart:async';

import 'package:flutter/material.dart';

import 'barcode_result.dart';
import 'scanner_controller.dart';
import 'scanner_options.dart';
import 'scanner_state.dart';

/// Displays the camera preview and reports detections.
///
/// The preview is a Flutter texture fed directly by the native camera, so no
/// frame data passes through Dart. The widget also owns the lifecycle: it
/// releases the camera when the app goes to the background and re-opens it on
/// return, and it stops the camera when it is removed from the tree.
class BarcodeScannerView extends StatefulWidget {
  const BarcodeScannerView({
    required this.controller,
    super.key,
    this.onDetected,
    this.onCapture,
    this.onError,
    this.fit = BoxFit.cover,
    this.autoStart = true,
    this.tapToFocus = true,
    this.scanWindow,
    this.overlay,
    this.placeholderBuilder,
    this.errorBuilder,
  });

  final BarcodeScannerController controller;

  /// Called once per barcode. With [ScanMode.multiple] this fires several
  /// times for the same frame.
  final void Function(BarcodeResult result)? onDetected;

  /// Called once per analysed frame that produced barcodes.
  final void Function(BarcodeCapture capture)? onCapture;

  /// Called when the scanner fails. Without an [errorBuilder] the widget also
  /// shows a default message.
  final void Function(BarcodeScannerException error)? onError;

  /// How the preview fills the widget. [BoxFit.cover] crops, which is what a
  /// full-screen scanner usually wants.
  final BoxFit fit;

  /// Start the camera as soon as the widget is mounted.
  final bool autoStart;

  /// Focus the camera where the user taps.
  final bool tapToFocus;

  /// Region of interest as a fraction of the preview (0..1). When set, the
  /// decoder only looks inside it and the area outside is dimmed.
  final Rect? scanWindow;

  /// Drawn on top of the preview, inside the same stack as the scan window.
  final Widget? overlay;

  /// Shown while the camera is opening.
  final WidgetBuilder? placeholderBuilder;

  /// Shown when the scanner is in [ScannerState.error].
  final Widget Function(BuildContext context, BarcodeScannerException error)?
  errorBuilder;

  @override
  State<BarcodeScannerView> createState() => _BarcodeScannerViewState();
}

class _BarcodeScannerViewState extends State<BarcodeScannerView>
    with WidgetsBindingObserver {
  StreamSubscription<BarcodeCapture>? _captures;
  bool _restartOnResume = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attach(widget.controller);
    if (widget.autoStart) {
      // start() is async and may fail; the controller records the error and
      // the widget renders it, so nothing is swallowed silently.
      unawaited(_start());
    }
  }

  @override
  void didUpdateWidget(BarcodeScannerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _detach(oldWidget.controller);
      _attach(widget.controller);
    }
    if (oldWidget.scanWindow != widget.scanWindow &&
        widget.controller.state == ScannerState.running) {
      unawaited(widget.controller.setScanRegion(widget.scanWindow));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detach(widget.controller);
    // The controller may outlive this widget (the caller owns it), so only
    // release the camera - never dispose the controller here.
    if (widget.controller.state != ScannerState.disposed) {
      unawaited(widget.controller.stop());
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = widget.controller;
    if (controller.state == ScannerState.disposed) return;
    switch (state) {
      case AppLifecycleState.resumed:
        if (_restartOnResume) {
          _restartOnResume = false;
          unawaited(_start());
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // Hold on to the camera in the background and another app - or the
        // system - will take it from us anyway. Release it deliberately.
        if (controller.state == ScannerState.running ||
            controller.state == ScannerState.paused) {
          _restartOnResume = true;
          unawaited(controller.stop());
        }
    }
  }

  Future<void> _start() async {
    try {
      await widget.controller.start();
      final window = widget.scanWindow;
      if (window != null && mounted) {
        await widget.controller.setScanRegion(window);
      }
    } on BarcodeScannerException catch (error) {
      widget.onError?.call(error);
    }
  }

  void _attach(BarcodeScannerController controller) {
    controller.addListener(_onControllerChanged);
    _captures = controller.captures.listen((capture) {
      widget.onCapture?.call(capture);
      final onDetected = widget.onDetected;
      if (onDetected == null) return;
      for (final barcode in capture.barcodes) {
        onDetected(barcode);
      }
    });
  }

  void _detach(BarcodeScannerController controller) {
    controller.removeListener(_onControllerChanged);
    unawaited(_captures?.cancel());
    _captures = null;
  }

  BarcodeScannerException? _lastReportedError;

  void _onControllerChanged() {
    final error = widget.controller.error;
    if (error != null && error != _lastReportedError) {
      _lastReportedError = error;
      widget.onError?.call(error);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final error = controller.error;
    if (controller.state == ScannerState.error && error != null) {
      return widget.errorBuilder?.call(context, error) ??
          _DefaultError(error: error);
    }

    final preview = controller.preview;
    if (preview == null) {
      return widget.placeholderBuilder?.call(context) ?? const _Placeholder();
    }

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _Preview(
            controller: controller,
            fit: widget.fit,
            onTapFocus: widget.tapToFocus ? _focusAt : null,
          ),
          if (widget.scanWindow != null)
            CustomPaint(painter: _ScanWindowPainter(widget.scanWindow!)),
          if (widget.overlay != null) widget.overlay!,
        ],
      ),
    );
  }

  Future<void> _focusAt(Offset normalized) async {
    try {
      await widget.controller.setFocusPoint(normalized);
    } on BarcodeScannerException {
      // Tap-to-focus is a nicety; a camera that refuses it is not an error
      // worth surfacing to the user.
    }
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.controller, required this.fit, this.onTapFocus});

  final BarcodeScannerController controller;
  final BoxFit fit;
  final Future<void> Function(Offset normalized)? onTapFocus;

  @override
  Widget build(BuildContext context) {
    final preview = controller.preview!;
    Widget texture = Texture(textureId: preview.textureId);

    if (preview.rotationDegrees != 0) {
      texture = RotatedBox(
        quarterTurns: (preview.rotationDegrees ~/ 90) % 4,
        child: texture,
      );
    }
    if (preview.isMirrored) {
      texture = Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()..scaleByDouble(-1, 1, 1, 1),
        child: texture,
      );
    }

    final oriented = preview.orientedPreviewSize;
    Widget sized = FittedBox(
      fit: fit,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: oriented.width,
        height: oriented.height,
        child: texture,
      ),
    );

    if (onTapFocus != null) {
      sized = _TapToFocus(onTap: onTapFocus!, child: sized);
    }
    return ClipRect(child: sized);
  }
}

class _TapToFocus extends StatelessWidget {
  const _TapToFocus({required this.onTap, required this.child});

  final Future<void> Function(Offset normalized) onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) return;
            unawaited(
              onTap(
                Offset(
                  (details.localPosition.dx / constraints.maxWidth).clamp(0, 1),
                  (details.localPosition.dy / constraints.maxHeight).clamp(0, 1),
                ),
              ),
            );
          },
          child: child,
        );
      },
    );
  }
}

/// Dims everything outside the scan window.
class _ScanWindowPainter extends CustomPainter {
  const _ScanWindowPainter(this.window);

  final Rect window;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      window.left * size.width,
      window.top * size.height,
      window.width * size.width,
      window.height * size.height,
    );
    final rounded = RRect.fromRectAndRadius(rect, const Radius.circular(12));

    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(rounded),
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    canvas.drawRRect(
      rounded,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(_ScanWindowPainter oldDelegate) =>
      oldDelegate.window != window;
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Colors.black,
    child: Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
      ),
    ),
  );
}

class _DefaultError extends StatelessWidget {
  const _DefaultError({required this.error});

  final BarcodeScannerException error;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            error.message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      ),
    );
  }
}
