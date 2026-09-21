// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "lightweight_barcode_scanner",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        // Flutter looks for the plugin's library under the hyphenated form of
        // the package name: it becomes the CFBundleIdentifier when the plugin
        // is linked dynamically, and those cannot contain underscores.
        .library(name: "lightweight-barcode-scanner", targets: ["lightweight_barcode_scanner"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        // Swift Package Manager will not mix languages inside one target, so
        // the C++/Objective-C++ side is its own target. `include` holds the
        // only public header - the Objective-C face of the decoder - while
        // `vendor_include` is a generated mirror of the shared core's headers
        // (see tool/generate_ios_sources.sh); SPM rejects a header search path
        // that points outside the package, so the mirror has to live in here.
        .target(
            name: "lbs_core",
            cxxSettings: [
                .headerSearchPath("vendor_include"),
                .define("ZXING_INTERNAL", to: "1")
            ],
            linkerSettings: [
                .linkedLibrary("c++")
            ]
        ),
        .target(
            name: "lightweight_barcode_scanner",
            dependencies: [
                "lbs_core",
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ],
    cxxLanguageStandard: .cxx20
)
