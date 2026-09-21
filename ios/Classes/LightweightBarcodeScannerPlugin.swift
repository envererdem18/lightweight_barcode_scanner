import AVFoundation
import Flutter
import UIKit

/// Method-channel front end.
///
/// It owns the scanner sessions and nothing else: camera work lives in
/// `ScannerSession` and decoding lives in the shared C++ core.
public class LightweightBarcodeScannerPlugin: NSObject, FlutterPlugin {
  private let registry: FlutterTextureRegistry
  private let messenger: FlutterBinaryMessenger
  private var sessions: [Int: ScannerSession] = [:]
  private var nextSessionId = 1

  init(registry: FlutterTextureRegistry, messenger: FlutterBinaryMessenger) {
    self.registry = registry
    self.messenger = messenger
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.enver.lightweight_barcode_scanner/methods",
      binaryMessenger: registrar.messenger()
    )
    let instance = LightweightBarcodeScannerPlugin(
      registry: registrar.textures(),
      messenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.publish(instance)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    releaseAllSessions()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "checkPermission":
      result(LightweightBarcodeScannerPlugin.permissionStatus())

    case "requestPermission":
      requestPermission(result: result)

    case "create":
      let id = nextSessionId
      nextSessionId += 1
      sessions[id] = ScannerSession(
        sessionId: id,
        registry: registry,
        messenger: messenger,
        configuration: ScannerConfiguration.from(arguments)
      )
      result(id)

    case "start":
      withSession(arguments, result) { session in
        session.start { outcome in
          switch outcome {
          case .success(let preview): result(preview)
          case .failure(let error): result(Self.flutterError(error))
          }
        }
      }

    case "pause":
      withSession(arguments, result) { $0.pause(); result(nil) }

    case "resume":
      withSession(arguments, result) { $0.resume(); result(nil) }

    case "stop", "dispose":
      if let id = arguments["sessionId"] as? Int {
        sessions.removeValue(forKey: id)?.release()
      }
      result(nil)

    case "setTorch":
      withSession(arguments, result) { session in
        self.attempt(result) {
          try session.setTorch(arguments["enabled"] as? Bool ?? false)
        }
      }

    case "setZoom":
      withSession(arguments, result) { session in
        self.attempt(result) {
          try session.setZoom((arguments["zoom"] as? NSNumber)?.doubleValue ?? 1)
        }
      }

    case "setFocusPoint":
      withSession(arguments, result) { session in
        self.attempt(result) {
          try session.setFocusPoint(
            x: (arguments["x"] as? NSNumber)?.doubleValue,
            y: (arguments["y"] as? NSNumber)?.doubleValue
          )
        }
      }

    case "switchCamera":
      withSession(arguments, result) { session in
        session.switchCamera(facing: arguments["facing"] as? String ?? "back") {
          outcome in
          switch outcome {
          case .success(let preview): result(preview)
          case .failure(let error): result(Self.flutterError(error))
          }
        }
      }

    case "setFormats":
      withSession(arguments, result) { session in
        session.setFormats((arguments["formats"] as? NSNumber)?.uint32Value ?? 0)
        result(nil)
      }

    case "setScanRegion":
      withSession(arguments, result) { session in
        var region: CGRect?
        if let values = arguments["scanRegion"] as? [NSNumber], values.count >= 4 {
          region = CGRect(
            x: values[0].doubleValue, y: values[1].doubleValue,
            width: values[2].doubleValue, height: values[3].doubleValue)
        }
        session.setScanRegion(region)
        result(nil)
      }

    case "setDuplicateFilter":
      withSession(arguments, result) { session in
        session.setDuplicateFilter(
          millis: (arguments["duplicateFilterMillis"] as? NSNumber)?.doubleValue ?? 0)
        result(nil)
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - helpers

  private func withSession(
    _ arguments: [String: Any],
    _ result: @escaping FlutterResult,
    _ body: (ScannerSession) -> Void
  ) {
    guard let id = arguments["sessionId"] as? Int, let session = sessions[id] else {
      result(
        FlutterError(
          code: "invalidState",
          message: "This scanner session is no longer available.",
          details: nil))
      return
    }
    body(session)
  }

  private func attempt(_ result: @escaping FlutterResult, _ body: () throws -> Void) {
    do {
      try body()
      result(nil)
    } catch {
      result(Self.flutterError(error))
    }
  }

  private static func flutterError(_ error: Error) -> FlutterError {
    if let scannerError = error as? ScannerError {
      return FlutterError(
        code: scannerError.code,
        message: scannerError.errorDescription,
        details: nil)
    }
    return FlutterError(
      code: "unknown", message: error.localizedDescription, details: nil)
  }

  private static func permissionStatus() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return "granted"
    case .denied: return "permanentlyDenied"
    case .restricted: return "restricted"
    case .notDetermined: return "denied"
    @unknown default: return "denied"
    }
  }

  private func requestPermission(result: @escaping FlutterResult) {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      result("granted")
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          // A denial at the system prompt is final: iOS never shows it twice.
          result(granted ? "granted" : "permanentlyDenied")
        }
      }
    case .denied:
      result("permanentlyDenied")
    case .restricted:
      result("restricted")
    @unknown default:
      result("denied")
    }
  }

  private func releaseAllSessions() {
    sessions.values.forEach { $0.release() }
    sessions.removeAll()
  }
}
