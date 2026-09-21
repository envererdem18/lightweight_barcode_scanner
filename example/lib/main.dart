import 'package:flutter/material.dart';
import 'package:lightweight_barcode_scanner/lightweight_barcode_scanner.dart';

void main() => runApp(const ScannerApp());

class ScannerApp extends StatelessWidget {
  const ScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lightweight Barcode Scanner',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3F51B5), brightness: Brightness.dark),
      home: const ScannerPage(),
    );
  }
}

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  static const Rect _scanWindow = Rect.fromLTWH(0.1, 0.3, 0.8, 0.4);

  late final BarcodeScannerController _controller;
  final List<BarcodeResult> _history = <BarcodeResult>[];
  bool _useScanWindow = true;
  double _zoom = 1;

  @override
  void initState() {
    super.initState();
    _controller = BarcodeScannerController(
      formats: {BarcodeFormat.qrCode, BarcodeFormat.ean13, BarcodeFormat.ean8, BarcodeFormat.code128, BarcodeFormat.code39},
      scanMode: ScanMode.multiple,
      duplicateFilterDuration: const Duration(seconds: 1),
      detectionsPerSecond: 12,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetected(BarcodeResult result) {
    setState(() {
      _history.insert(0, result);
      if (_history.length > 12) _history.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lightweight Barcode Scanner'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Scan region',
            icon: Icon(_useScanWindow ? Icons.crop_free : Icons.fullscreen),
            onPressed: () => setState(() => _useScanWindow = !_useScanWindow),
          ),
          IconButton(
            tooltip: 'Switch camera',
            icon: const Icon(Icons.cameraswitch_outlined),
            onPressed: _controller.isRunning ? _switchCamera : null,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: BarcodeScannerView(
              controller: _controller,
              scanWindow: _useScanWindow ? _scanWindow : null,
              onDetected: _onDetected,
              overlay: _Controls(controller: _controller, zoom: _zoom, onZoomChanged: _setZoom),
            ),
          ),
          Expanded(flex: 2, child: _History(results: _history)),
        ],
      ),
    );
  }

  Future<void> _switchCamera() async {
    await _controller.switchCamera();
    setState(() => _zoom = 1);
  }

  Future<void> _setZoom(double zoom) async {
    setState(() => _zoom = zoom);
    await _controller.setZoom(zoom);
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.controller, required this.zoom, required this.onZoomChanged});

  final BarcodeScannerController controller;
  final double zoom;
  final ValueChanged<double> onZoomChanged;

  @override
  Widget build(BuildContext context) {
    final preview = controller.preview;
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (preview?.hasTorch ?? false)
                IconButton.filledTonal(
                  icon: Icon(controller.torchEnabled ? Icons.flashlight_on : Icons.flashlight_off),
                  onPressed: controller.toggleTorch,
                ),
              if (preview != null && preview.maxZoom > preview.minZoom)
                SizedBox(
                  width: 180,
                  child: Slider(
                    value: zoom.clamp(preview.minZoom, preview.maxZoom),
                    min: preview.minZoom,
                    max: preview.maxZoom,
                    onChanged: onZoomChanged,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _History extends StatelessWidget {
  const _History({required this.results});

  final List<BarcodeResult> results;

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return const Center(child: Text('Point the camera at a barcode.'));
    }
    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final result = results[index];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.qr_code_2),
          title: Text(result.value, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(result.format.name),
        );
      },
    );
  }
}
