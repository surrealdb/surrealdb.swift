// swift-tools-version: 6.1

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "SurrealDB",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "SurrealDB", targets: ["SurrealDB"]),
        .library(name: "AgentMemory", targets: ["AgentMemory"])
    ],
    dependencies: [
        .package(url: "https://github.com/outfoxx/PotentCodables.git", from: "3.5.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "601.0.1")
    ],
    targets: [
        .target(
            name: "SurrealDBMacros"
        ),
        .macro(
            name: "SurrealDBMacroPlugin",
            dependencies: [
                "SurrealDBMacros",
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax")
            ]
        ),
        .target(
            name: "SurrealDB",
            dependencies: [
                "SurrealDBMacros",
                "SurrealDBMacroPlugin",
                .product(name: "PotentCodables", package: "PotentCodables")
            ]
        ),
        .testTarget(
            name: "SurrealDBTests",
            dependencies: [
                "SurrealDB",
                "SurrealDBMacroPlugin",
                "SurrealConformance",
                .product(name: "PotentCodables", package: "PotentCodables"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ]
        ),
        // Shared by the vector tests and the conformance driver: typed JSON,
        // the value notation of surrealdb-protocol's vectors and scenarios.
        .target(
            name: "SurrealConformance",
            dependencies: ["SurrealDB"],
            path: "Conformance/TypedJSON"
        ),
        // The driver surrealdb-protocol's conformance runner talks to. Not a
        // product: build it with `swift build --product SurrealConformanceDriver`.
        .executableTarget(
            name: "SurrealConformanceDriver",
            dependencies: ["SurrealDB", "SurrealConformance"],
            path: "Conformance/Driver"
        ),
        .target(
            name: "AgentMemory"
        ),
        .testTarget(
            name: "AgentMemoryTests",
            dependencies: ["AgentMemory"]
        )
    ]
)
