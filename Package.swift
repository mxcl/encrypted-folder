// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "EncryptedFolder",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "EncryptedFolderCore", targets: ["EncryptedFolderCore"]),
    .executable(name: "EncryptedFolder", targets: ["EncryptedFolder"]),
  ],
  targets: [
    .target(
      name: "EncryptedFolderCore",
      resources: [.copy("Resources/RECOVER.command")]
    ),
    .executableTarget(
      name: "EncryptedFolder",
      dependencies: ["EncryptedFolderCore"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("AVKit"),
        .linkedFramework("LocalAuthentication"),
        .linkedFramework("PDFKit"),
        .linkedFramework("Security"),
      ]
    ),
    .testTarget(name: "EncryptedFolderCoreTests", dependencies: ["EncryptedFolderCore"]),
  ]
)
