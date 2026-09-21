import AVFoundation
import Foundation

/// Scanner settings as they arrive from Dart.
struct ScannerConfiguration {
  var formats: UInt32
  var scanMode: String
  var facing: String
  var resolution: AVCaptureSession.Preset
  var profile: String
  var duplicateFilterMillis: Double
  var detectionsPerSecond: Int
  var includeRawBytes: Bool
  var torchEnabled: Bool
  var scanRegion: CGRect?

  var isFrontFacing: Bool { facing == "front" }
  var maxSymbols: Int { scanMode == "multiple" ? 16 : 1 }
  var stopAfterFirstResult: Bool { scanMode == "single" }

  /// Minimum gap between decode attempts. Surplus frames are dropped.
  var minAnalysisInterval: CFTimeInterval { 1.0 / Double(detectionsPerSecond) }

  var tryHarder: Bool { profile != "fast" }
  var tryRotate: Bool { profile != "fast" }
  var tryInvert: Bool { profile == "thorough" }
  var tryDownscale: Bool { profile != "fast" }

  static func from(_ arguments: [String: Any]) -> ScannerConfiguration {
    var region: CGRect?
    if let values = arguments["scanRegion"] as? [NSNumber], values.count >= 4 {
      region = CGRect(
        x: values[0].doubleValue,
        y: values[1].doubleValue,
        width: values[2].doubleValue,
        height: values[3].doubleValue
      )
    }
    return ScannerConfiguration(
      formats: (arguments["formats"] as? NSNumber)?.uint32Value ?? 0,
      scanMode: arguments["scanMode"] as? String ?? "continuous",
      facing: arguments["facing"] as? String ?? "back",
      resolution: preset(for: arguments["resolution"] as? String),
      profile: arguments["profile"] as? String ?? "balanced",
      duplicateFilterMillis:
        (arguments["duplicateFilterMillis"] as? NSNumber)?.doubleValue ?? 750,
      detectionsPerSecond: min(
        60, max(1, (arguments["detectionsPerSecond"] as? NSNumber)?.intValue ?? 12)),
      includeRawBytes: arguments["includeRawBytes"] as? Bool ?? false,
      torchEnabled: arguments["torchEnabled"] as? Bool ?? false,
      scanRegion: region
    )
  }

  private static func preset(for name: String?) -> AVCaptureSession.Preset {
    switch name {
    case "low": return .vga640x480
    case "high": return .hd1920x1080
    default: return .hd1280x720
    }
  }
}
