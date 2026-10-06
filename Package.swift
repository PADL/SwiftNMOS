// swift-tools-version:6.2

import PackageDescription

let package = Package(
  name: "SwiftNMOS",
  platforms: [
    .macOS(.v15),
    .iOS(.v18),
  ],
  products: [
    .library(name: "NMOS", targets: ["NMOS"]),
    .library(name: "NMOSOCABridge", targets: ["NMOSOCABridge"]),
    .library(name: "SwiftOCAClassManager", targets: ["SwiftOCAClassManager"]),
  ],
  traits: [
    .init(
      name: "DescribeVendorMethods",
      description: "Describe vendor methods over IS-12, which are callable regardless"
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/PADL/SwiftOCA", branch: "main"),
    .package(url: "https://github.com/swhitty/FlyingFox", from: "0.26.2"),
    .package(url: "https://github.com/apple/swift-log", from: "1.6.2"),
    .package(url: "https://github.com/apple/swift-crypto", from: "3.10.0"),
  ],
  targets: [
    // AMWA NMOS node protocols (IS-04, IS-05, IS-12); knows nothing of OCA
    .target(
      name: "NMOS",
      dependencies: [
        .product(name: "FlyingFox", package: "FlyingFox"),
        .product(name: "FlyingSocks", package: "FlyingFox"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    // a class manager for OCA, which AES70 lacks: its datatypes and its controller API
    .target(
      name: "SwiftOCAClassManager",
      dependencies: [
        .product(name: "SwiftOCA", package: "SwiftOCA"),
      ]
    ),
    // presents a SwiftOCADevice object model through the NMOS target
    .target(
      name: "NMOSOCABridge",
      dependencies: [
        "NMOS",
        "SwiftOCAClassManager",
        .product(name: "SwiftOCA", package: "SwiftOCA"),
        .product(name: "SwiftOCADevice", package: "SwiftOCA"),
        .product(name: "FlyingFox", package: "FlyingFox"),
        .product(name: "Logging", package: "swift-log"),
      ],
      exclude: ["IS12/README.md"]
    ),
    // an AES70 device with mock AES67 and Dante transports, served as an NMOS node
    .executableTarget(
      name: "NMOSDevice",
      dependencies: [
        "NMOS",
        "NMOSOCABridge",
        .product(name: "SwiftOCA", package: "SwiftOCA"),
        .product(name: "SwiftOCADevice", package: "SwiftOCA"),
        .product(name: "Logging", package: "swift-log"),
      ],
      path: "Examples/NMOSDevice"
    ),
    .testTarget(
      name: "NMOSTests",
      dependencies: [
        "NMOS",
        .product(name: "FlyingFox", package: "FlyingFox"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .testTarget(
      name: "NMOSOCABridgeTests",
      dependencies: [
        "NMOS",
        "NMOSOCABridge",
        "SwiftOCAClassManager",
        .product(name: "SwiftOCA", package: "SwiftOCA"),
        .product(name: "SwiftOCADevice", package: "SwiftOCA"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
  ]
)
