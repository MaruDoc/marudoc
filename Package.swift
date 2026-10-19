// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Enso",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EnsoApp", targets: ["EnsoApp"]),
        .executable(name: "EnsoFinderSync", targets: ["EnsoFinderSync"]),
        .executable(name: "ensocli", targets: ["ensocli"]),
    ],
    targets: [
        // Shared between the app and the Finder extension: file kinds, action catalog, URL scheme.
        .target(name: "EnsoShared"),
        // Intermediate document model + simple readers/writers (Markdown, HTML, text, RTF, PDF rendering).
        .target(name: "EnsoDoc", dependencies: ["EnsoShared"]),
        // ZIP container + Office Open XML (docx / xlsx / pptx) readers and writers.
        .target(name: "EnsoOffice", dependencies: ["EnsoDoc"]),
        // PDF analysis: layout reconstruction, table extraction, image extraction, OCR.
        .target(name: "EnsoPDF", dependencies: ["EnsoDoc"]),
        // Action execution: conversions, PDF / image operations, output naming.
        .target(name: "EnsoCore", dependencies: ["EnsoShared", "EnsoDoc", "EnsoOffice", "EnsoPDF"]),
        .executableTarget(name: "EnsoApp", dependencies: ["EnsoCore", "EnsoDoc", "EnsoOffice", "EnsoShared"]),
        .executableTarget(
            name: "EnsoFinderSync",
            dependencies: ["EnsoShared"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(name: "ensocli", dependencies: ["EnsoCore", "EnsoOffice"]),
    ],
    swiftLanguageModes: [.v5]
)
