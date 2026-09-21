import AVFoundation
import Flutter
import UIKit

// Under CocoaPods the Objective-C++ decoder and this file end up in the same
// module, so there is nothing to import. Swift Package Manager keeps them in
// separate targets, because it will not mix languages inside one.
#if canImport(lbs_core)
  import lbs_core
#endif

/// One camera session: AVFoundation for acquisition, the shared C++ core for
/// decoding, a Flutter texture for the preview.
///
/// Frame path (see doc/ARCHITECTURE.md):
///
///   source    : AVCaptureVideoDataOutput, 420YpCbCr8BiPlanarFullRange (NV12)
///   preview   : the CVPixelBuffer is retained and handed to Flutter's texture
///               registry. Retained, never copied, never seen by Dart.
///   analysis  : plane 0 (luminance) of that same buffer is passed straight to
///               the decoder. No colour conversion, no copy.
///   thread    : `captureQueue`, a serial queue. Decoding happens inline on
///               it, so at most one decode is ever in flight, and
///               `alwaysDiscardsLateVideoFrames` drops whatever arrives in the
///               meantime rather than queueing it.
final class ScannerSession: NSObject {
  private let sessionId: Int
  private let registry: FlutterTextureRegistry
  private let eventChannel: FlutterEventChannel
  private var configuration: ScannerConfiguration

  private let session = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let captureQueue = DispatchQueue(
    label: "dev.enver.lightweight_barcode_scanner.capture",
    qos: .userInitiated
  )
  private var device: AVCaptureDevice?
  private var input: AVCaptureDeviceInput?

  private let decoder = LBSDecoder()
  private var textureId: Int64 = -1
  private var eventSink: FlutterEventSink?
  private var released = false

  // Touched only on captureQueue.
  private var latestBuffer: CVPixelBuffer?
  private let bufferLock = NSLock()
  private var analyzing = false
  private var lastAnalysisAt: CFTimeInterval = 0
  private var appliedRotation = Int.min
  private var appliedFormats = UInt32.max
  private var appliedCrop: CGRect?
  private var optionsDirty = true
  private var recentResults: [String: CFTimeInterval] = [:]

  private var analysisSize = CGSize.zero
  private var rotationDegrees = 90

  init(
    sessionId: Int,
    registry: FlutterTextureRegistry,
    messenger: FlutterBinaryMessenger,
    configuration: ScannerConfiguration
  ) {
    self.sessionId = sessionId
    self.registry = registry
    self.configuration = configuration
    self.eventChannel = FlutterEventChannel(
      name: "\(ScannerSession.eventChannelPrefix)/\(sessionId)",
      binaryMessenger: messenger
    )
    super.init()
    eventChannel.setStreamHandler(self)
  }

  static let eventChannelPrefix = "dev.enver.lightweight_barcode_scanner/events"

  // MARK: - lifecycle

  func start(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    do {
      try configureSession()
    } catch {
      completion(.failure(error))
      return
    }

    textureId = registry.register(self)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(orientationChanged),
      name: UIDevice.orientationDidChangeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(sessionInterrupted(_:)),
      name: .AVCaptureSessionWasInterrupted,
      object: session
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(sessionRuntimeError(_:)),
      name: .AVCaptureSessionRuntimeError,
      object: session
    )

    updateRotation()
    captureQueue.async { [weak self] in
      guard let self, !self.released else { return }
      self.analyzing = true
      self.session.startRunning()
      DispatchQueue.main.async {
        if self.configuration.torchEnabled { try? self.setTorch(true) }
        completion(.success(self.describe()))
      }
    }
  }

  private func configureSession() throws {
    let position: AVCaptureDevice.Position =
      configuration.isFrontFacing ? .front : .back
    guard let device = ScannerSession.camera(for: position) else {
      throw ScannerError.cameraUnavailable
    }
    self.device = device

    session.beginConfiguration()
    defer { session.commitConfiguration() }

    if session.canSetSessionPreset(configuration.resolution) {
      session.sessionPreset = configuration.resolution
    } else {
      session.sessionPreset = .high
    }

    if let existing = input {
      session.removeInput(existing)
    }
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw ScannerError.cameraUnavailable }
    session.addInput(input)
    self.input = input

    if !session.outputs.contains(videoOutput) {
      // Full-range NV12: the Y plane is the luminance image the decoder wants,
      // and the engine can render the same buffer as a texture.
      videoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String:
          kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      ]
      videoOutput.alwaysDiscardsLateVideoFrames = true
      videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
      guard session.canAddOutput(videoOutput) else {
        throw ScannerError.cameraInitializationFailed
      }
      session.addOutput(videoOutput)
    }

    // Leave the buffer in its native sensor orientation: rotating it here would
    // cost a full-frame transform per frame. The decoder gets the angle as
    // metadata and Flutter rotates the texture for display.
    if let connection = videoOutput.connection(with: .video) {
      if #available(iOS 17.0, *) {
        if connection.isVideoRotationAngleSupported(0) {
          connection.videoRotationAngle = 0
        }
      } else if connection.isVideoOrientationSupported {
        connection.videoOrientation = .landscapeRight
      }
      connection.isVideoMirrored = false
    }

    configureDevice(device)
  }

  /// Continuous autofocus and exposure - a correct decoder with bad focus is
  /// still a bad scanner.
  private func configureDevice(_ device: AVCaptureDevice) {
    guard (try? device.lockForConfiguration()) != nil else { return }
    defer { device.unlockForConfiguration() }

    if device.isFocusModeSupported(.continuousAutoFocus) {
      device.focusMode = .continuousAutoFocus
    }
    if device.isAutoFocusRangeRestrictionSupported {
      // Barcodes are close; this keeps the lens from hunting to infinity.
      device.autoFocusRangeRestriction = .near
    }
    if device.isExposureModeSupported(.continuousAutoExposure) {
      device.exposureMode = .continuousAutoExposure
    }
    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
      device.whiteBalanceMode = .continuousAutoWhiteBalance
    }
    if device.isSmoothAutoFocusSupported {
      device.isSmoothAutoFocusEnabled = true
    }
  }

  func pause() {
    captureQueue.async { [weak self] in self?.analyzing = false }
  }

  func resume() {
    captureQueue.async { [weak self] in
      self?.analyzing = true
      self?.recentResults.removeAll()
    }
  }

  func release() {
    guard !released else { return }
    released = true
    NotificationCenter.default.removeObserver(self)
    eventChannel.setStreamHandler(nil)
    eventSink = nil

    if session.isRunning { session.stopRunning() }
    videoOutput.setSampleBufferDelegate(nil, queue: nil)
    session.beginConfiguration()
    session.inputs.forEach(session.removeInput)
    session.outputs.forEach(session.removeOutput)
    session.commitConfiguration()

    if textureId >= 0 {
      registry.unregisterTexture(textureId)
      textureId = -1
    }
    bufferLock.lock()
    latestBuffer = nil
    bufferLock.unlock()
    device = nil
    input = nil
  }

  // MARK: - camera controls

  func setTorch(_ enabled: Bool) throws {
    guard let device, device.hasTorch else {
      throw ScannerError.unsupportedOperation("This camera has no torch.")
    }
    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }
    device.torchMode = enabled ? .on : .off
  }

  func setZoom(_ zoom: Double) throws {
    guard let device else { throw ScannerError.invalidState }
    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }
    let maximum = min(device.activeFormat.videoMaxZoomFactor, 16)
    device.videoZoomFactor = min(max(zoom, 1), maximum)
  }

  /// `x` and `y` are fractions of the preview; nil restores autofocus.
  func setFocusPoint(x: Double?, y: Double?) throws {
    guard let device else { throw ScannerError.invalidState }
    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }

    guard let x, let y else {
      if device.isFocusModeSupported(.continuousAutoFocus) {
        device.focusMode = .continuousAutoFocus
      }
      if device.isExposureModeSupported(.continuousAutoExposure) {
        device.exposureMode = .continuousAutoExposure
      }
      return
    }

    // AVFoundation points are in the sensor's landscape-right space, which is
    // the preview rotated back by `rotationDegrees`.
    let point = unrotate(CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)))
    if device.isFocusPointOfInterestSupported {
      device.focusPointOfInterest = point
      if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
    }
    if device.isExposurePointOfInterestSupported {
      device.exposurePointOfInterest = point
      if device.isExposureModeSupported(.autoExpose) {
        device.exposureMode = .autoExpose
      }
    }
  }

  func switchCamera(
    facing: String, completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    configuration.facing = facing
    configuration.torchEnabled = false
    do {
      try configureSession()
      updateRotation()
      completion(.success(describe()))
    } catch {
      completion(.failure(error))
    }
  }

  func setFormats(_ formats: UInt32) {
    captureQueue.async { [weak self] in
      self?.configuration.formats = formats
      self?.optionsDirty = true
    }
  }

  func setScanRegion(_ region: CGRect?) {
    captureQueue.async { [weak self] in
      self?.configuration.scanRegion = region
      self?.optionsDirty = true
    }
  }

  func setDuplicateFilter(millis: Double) {
    captureQueue.async { [weak self] in
      self?.configuration.duplicateFilterMillis = millis
      self?.recentResults.removeAll()
    }
  }

  var hasTorch: Bool { device?.hasTorch ?? false }

  // MARK: - geometry

  private func updateRotation() {
    let orientation = UIDevice.current.orientation
    let degrees: Int
    switch orientation {
    case .landscapeLeft: degrees = 180
    case .landscapeRight: degrees = 0
    case .portraitUpsideDown: degrees = 270
    default: degrees = 90
    }
    if degrees != rotationDegrees {
      rotationDegrees = degrees
      captureQueue.async { [weak self] in self?.optionsDirty = true }
    }
  }

  @objc private func orientationChanged() {
    guard !released else { return }
    let previous = rotationDegrees
    updateRotation()
    if previous != rotationDegrees { emitPreview() }
  }

  /// Maps a normalised preview point back into the sensor's own space.
  private func unrotate(_ point: CGPoint) -> CGPoint {
    switch rotationDegrees {
    case 90: return CGPoint(x: point.y, y: 1 - point.x)
    case 180: return CGPoint(x: 1 - point.x, y: 1 - point.y)
    case 270: return CGPoint(x: 1 - point.y, y: point.x)
    default: return point
    }
  }

  func describe() -> [String: Any] {
    let dimensions = device.map {
      CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription)
    }
    let width = Int(dimensions?.width ?? 0)
    let height = Int(dimensions?.height ?? 0)
    let rotated = rotationDegrees % 180 != 0
    let analysis = analysisSize == .zero
      ? CGSize(width: rotated ? height : width, height: rotated ? width : height)
      : analysisSize
    return [
      "textureId": textureId,
      "previewWidth": width,
      "previewHeight": height,
      "analysisWidth": Int(analysis.width),
      "analysisHeight": Int(analysis.height),
      "rotationDegrees": rotationDegrees,
      "facing": configuration.facing,
      "isMirrored": configuration.isFrontFacing,
      "hasTorch": hasTorch,
      "minZoom": 1.0,
      "maxZoom": min(device?.activeFormat.videoMaxZoomFactor ?? 1, 16),
    ]
  }

  private static func camera(for position: AVCaptureDevice.Position)
    -> AVCaptureDevice?
  {
    let types: [AVCaptureDevice.DeviceType] = [
      .builtInWideAngleCamera,
      .builtInDualCamera,
      .builtInTripleCamera,
    ]
    return AVCaptureDevice.DiscoverySession(
      deviceTypes: types, mediaType: .video, position: position
    ).devices.first ?? AVCaptureDevice.default(for: .video)
  }

  // MARK: - events

  @objc private func sessionInterrupted(_ notification: Notification) {
    emitError(code: "cameraInterrupted", message: "The camera was interrupted.")
  }

  @objc private func sessionRuntimeError(_ notification: Notification) {
    let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
    emitError(
      code: "cameraUnavailable",
      message: error?.localizedDescription ?? "The camera stopped unexpectedly."
    )
  }

  private func emitPreview() {
    guard !released else { return }
    var payload = describe()
    payload["type"] = "preview"
    DispatchQueue.main.async { [weak self] in self?.eventSink?(payload) }
  }

  private func emitError(code: String, message: String) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(FlutterError(code: code, message: message, details: nil))
    }
  }
}

// MARK: - frame delivery

extension ScannerSession: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard !released,
      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    else { return }

    // Retain the buffer for the preview. Retaining is not copying: Flutter
    // reads the very same memory the camera wrote.
    bufferLock.lock()
    latestBuffer = pixelBuffer
    bufferLock.unlock()
    let textureId = self.textureId
    if textureId >= 0 { registry.textureFrameAvailable(textureId) }

    guard analyzing else { return }
    let now = CACurrentMediaTime()
    guard now - lastAnalysisAt >= configuration.minAnalysisInterval else { return }
    lastAnalysisAt = now

    analyze(pixelBuffer, at: now)
  }

  private func analyze(_ pixelBuffer: CVPixelBuffer, at now: CFTimeInterval) {
    guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
    else { return }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard
      let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
    else { return }
    let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let rowStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

    let rotated = rotationDegrees % 180 != 0
    let rotatedWidth = rotated ? height : width
    let rotatedHeight = rotated ? width : height
    applyOptions(rotatedWidth: rotatedWidth, rotatedHeight: rotatedHeight)

    let barcodes = decoder.decodeLuminance(
      base.assumingMemoryBound(to: UInt8.self),
      size: UInt(rowStride * height),
      width: width,
      height: height,
      rowStride: rowStride,
      pixelStride: 1,
      includeBytes: configuration.includeRawBytes
    )
    guard let barcodes, !barcodes.isEmpty else { return }

    let accepted = barcodes.filter { !$0.text.isEmpty && accept($0, at: now) }
    guard !accepted.isEmpty else { return }

    if analysisSize.width != CGFloat(rotatedWidth)
      || analysisSize.height != CGFloat(rotatedHeight)
    {
      analysisSize = CGSize(width: rotatedWidth, height: rotatedHeight)
    }

    var imageWidth = rotatedWidth
    var imageHeight = rotatedHeight
    if let crop = configuration.scanRegion {
      imageWidth = max(1, Int(crop.width * CGFloat(rotatedWidth)))
      imageHeight = max(1, Int(crop.height * CGFloat(rotatedHeight)))
    }

    let payload: [String: Any] = [
      "type": "barcodes",
      "imageWidth": imageWidth,
      "imageHeight": imageHeight,
      "barcodes": accepted.map { barcode -> [String: Any] in
        var item: [String: Any] = [
          "value": barcode.text,
          "format": barcode.format,
          "orientation": barcode.orientation,
          "corners": barcode.corners,
        ]
        if let bytes = barcode.bytes { item["bytes"] = FlutterStandardTypedData(bytes: bytes) }
        return item
      },
    ]
    DispatchQueue.main.async { [weak self] in self?.eventSink?(payload) }

    if configuration.stopAfterFirstResult { analyzing = false }
  }

  /// Pushes configuration into the native decoder, but only when it moved.
  private func applyOptions(rotatedWidth: Int, rotatedHeight: Int) {
    let crop = configuration.scanRegion
    guard optionsDirty
      || rotationDegrees != appliedRotation
      || configuration.formats != appliedFormats
      || crop != appliedCrop
    else { return }

    var cropLeft = 0
    var cropTop = 0
    var cropWidth = 0
    var cropHeight = 0
    if let crop, rotatedWidth > 0, rotatedHeight > 0 {
      cropLeft = min(max(Int(crop.minX * CGFloat(rotatedWidth)), 0), rotatedWidth - 1)
      cropTop = min(max(Int(crop.minY * CGFloat(rotatedHeight)), 0), rotatedHeight - 1)
      cropWidth = min(max(1, Int(crop.width * CGFloat(rotatedWidth))), rotatedWidth - cropLeft)
      cropHeight = min(
        max(1, Int(crop.height * CGFloat(rotatedHeight))), rotatedHeight - cropTop)
    }

    decoder.setFormats(
      configuration.formats,
      tryHarder: configuration.tryHarder,
      tryRotate: configuration.tryRotate,
      tryInvert: configuration.tryInvert,
      tryDownscale: configuration.tryDownscale,
      maxSymbols: configuration.maxSymbols,
      rotation: rotationDegrees,
      cropLeft: cropLeft,
      cropTop: cropTop,
      cropWidth: cropWidth,
      cropHeight: cropHeight
    )

    appliedRotation = rotationDegrees
    appliedFormats = configuration.formats
    appliedCrop = crop
    optionsDirty = false
  }

  /// Duplicate suppression on `format + value`, as configured from Dart.
  private func accept(_ barcode: LBSBarcode, at now: CFTimeInterval) -> Bool {
    let window = configuration.duplicateFilterMillis / 1000
    guard window > 0 else { return true }
    let key = "\(barcode.format):\(barcode.text)"
    if let last = recentResults[key], now - last < window { return false }
    recentResults[key] = now
    if recentResults.count > 64 {
      recentResults = recentResults.filter { now - $0.value < window }
    }
    return true
  }
}

// MARK: - Flutter texture

extension ScannerSession: FlutterTexture {
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    bufferLock.lock()
    defer { bufferLock.unlock() }
    guard let buffer = latestBuffer else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  func onTextureUnregistered(_ texture: FlutterTexture) {
    bufferLock.lock()
    latestBuffer = nil
    bufferLock.unlock()
  }
}

// MARK: - stream handler

extension ScannerSession: FlutterStreamHandler {
  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}

enum ScannerError: LocalizedError {
  case cameraUnavailable
  case cameraInitializationFailed
  case invalidState
  case unsupportedOperation(String)

  var code: String {
    switch self {
    case .cameraUnavailable: return "cameraUnavailable"
    case .cameraInitializationFailed: return "cameraInitializationFailed"
    case .invalidState: return "invalidState"
    case .unsupportedOperation: return "unsupportedOperation"
    }
  }

  var errorDescription: String? {
    switch self {
    case .cameraUnavailable:
      return "No usable camera was found on this device."
    case .cameraInitializationFailed:
      return "The camera could not be configured."
    case .invalidState:
      return "The camera is not running."
    case .unsupportedOperation(let message):
      return message
    }
  }
}
