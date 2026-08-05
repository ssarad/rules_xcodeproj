import Foundation

// MARK: - Helpers

enum PathKey: String {
    case emitABIDescriptorPath = "-emit-abi-descriptor-path"
    case emitConstValuesPath = "-emit-const-values-path"
    case emitDependenciesPath = "-emit-dependencies-path"
    case emitModuleDocPath = "-emit-module-doc-path"
    case emitModulePath = "-emit-module-path"
    case emitModuleSourceInfoPath = "-emit-module-source-info-path"
    case emitObjCHeaderPath = "-emit-objc-header-path"
    case emitReferenceDependenciesPath = "-emit-reference-dependencies-path"
    case outputFileMap = "-output-file-map"
    case output = "-o"
    case primaryFile = "-primary-file"
    case sdk = "-sdk"
    case serializeDiagnosticsPath = "-serialize-diagnostics-path"
}

enum StringKey: String {
    case moduleName = "-module-name"
    case target = "-target"
}

func processArgs(
    _ args: [String]
) async throws -> (
    isPreviewThunk: Bool,
    isWMO: Bool,
    paths: [PathKey: URL],
    includePaths: [URL],
    moduleName: String?,
    target: String?
) {
    var isPreviewThunk = false
    var isWMO = false
    var paths: [PathKey: URL] = [:]
    var includePaths: [URL] = []
    var values: [StringKey: String] = [:]

    var previousArg: String?
    func processArg(_ arg: String) {
        if arg.hasPrefix("-output-file-map=") {
            paths[.outputFileMap] = URL(
                fileURLWithPath: String(arg.dropFirst("-output-file-map=".count))
            )
            previousArg = nil
            return
        }
        if let rawKey = previousArg {
            if rawKey == "-I" {
                includePaths.append(URL(fileURLWithPath: arg))
                previousArg = nil
                return
            }
            if let key = PathKey(rawValue: rawKey) {
                paths[key] = URL(fileURLWithPath: arg)
                previousArg = nil
                return
            }
            if let key = StringKey(rawValue: rawKey) {
                values[key] = arg
                previousArg = nil
                return
            }
        }

        if arg == "-wmo" || arg == "-whole-module-optimization" {
            isWMO = true
        } else if arg.hasPrefix("-I"), arg.count > 2 {
            includePaths.append(URL(fileURLWithPath: String(arg.dropFirst(2))))
        } else if arg.hasSuffix(".preview-thunk.swift") {
            isPreviewThunk = true
        } else {
            previousArg = arg
        }
    }

    for arg in args {
        if arg.hasPrefix("@") {
            let argumentFileURL
                = URL(fileURLWithPath: String(arg.dropFirst()))
            for try await line in argumentFileURL.lines {
                if line.hasPrefix(#"""#) && line.hasSuffix(#"""#) {
                    processArg(String(line.dropFirst().dropLast()))
                } else {
                    processArg(String(line))
                }
            }
        } else {
            processArg(arg)
        }
    }

    return (
        !paths.keys.contains(.outputFileMap) && isPreviewThunk,
        isWMO,
        paths,
        includePaths,
        values[.moduleName],
        values[.target]
    )
}

extension URL {
    mutating func touch() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: path) {
            fileManager.createFile(atPath: path, contents: nil)
        } else {
            var resourceValues = URLResourceValues()
            resourceValues.contentModificationDate = Date()
            try setResourceValues(resourceValues)
        }
    }
}

func writeData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
}

func copyFileOverwriting(source: URL, destination: URL) throws {
    guard source.standardizedFileURL.path != destination.standardizedFileURL.path else {
        return
    }

    let fileManager = FileManager.default
    try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
    }
    try fileManager.copyItem(at: source, to: destination)
}

func bazelPackageBinDirectory() -> URL? {
    let environment = ProcessInfo.processInfo.environment
    guard let bazelOut = environment["BAZEL_OUT"],
          let packageBinDir = environment["BAZEL_PACKAGE_BIN_DIR"]
    else {
        return nil
    }

    let relativePackage = packageBinDir.hasPrefix("bazel-out/")
        ? String(packageBinDir.dropFirst("bazel-out/".count))
        : packageBinDir
    return URL(fileURLWithPath: bazelOut)
        .appendingPathComponent(relativePackage)
}

func readOutputFileMap(
    paths: [PathKey: URL]
) throws -> [String: [String: Any]]? {
    guard let outputFileMapPath = paths[PathKey.outputFileMap] else {
        return nil
    }

    let data = try Data(contentsOf: outputFileMapPath)
    let rawOutputFileMap = try JSONSerialization.jsonObject(
        with: data,
        options: []
    )
    return rawOutputFileMap as? [String: [String: Any]]
}

/// Touch the Xcode-required `.d` files
func touchDepsFiles(isWMO: Bool, paths: [PathKey: URL]) throws {
    if var dependenciesPath = paths[.emitDependenciesPath] {
        try dependenciesPath.touch()
    }

    guard let outputFileMapPath = paths[PathKey.outputFileMap] else { return }

    if isWMO {
        // Xcode 26 beta 3 changed the naming convention for .d files of WMO modules to
        // use a suffix of "-primary" instead of "-master". Support both for now.
        let basePath = outputFileMapPath.path.dropLast("-OutputFileMap.json".count)
        for suffix in ["-master", "-primary"] {
            let dPath = "\(basePath)\(suffix).d"
            var url = URL(fileURLWithPath: dPath)
            try url.touch()
        }
    } else {
        guard let outputFileMap = try readOutputFileMap(paths: paths)
        else { return }

        for entry in outputFileMap.values {
            for key in ["dependencies", "emit-module-dependencies"] {
                guard let dPath = entry[key] as? String else {
                    continue
                }
                var url = URL(fileURLWithPath: dPath)
                try url.touch()
            }
        }
    }
}

func xcodeDefaultToolPath(
    tool: String,
    sdkPath: String
) throws -> String? {
    let fullRange = NSRange(sdkPath.startIndex..., in: sdkPath)
    let matches = try NSRegularExpression(
        pattern: #"(.*?/Contents/Developer)/.*"#
    ).matches(in: sdkPath, range: fullRange)
    guard let match = matches.first,
        let range = Range(match.range(at: 1), in: sdkPath)
    else {
        return nil
    }

    return """
\(sdkPath[range])/Toolchains/XcodeDefault.xctoolchain/usr/bin/\(tool)
"""
}

/// Materialize source outputs so Xcode can build a source-to-object map.
func createObjectFiles(
    paths: [PathKey: URL],
    target: String?
) throws {
    var objectPaths = try readOutputFileMap(paths: paths)?
        .filter { !$0.key.isEmpty }
        .compactMap { $0.value["object"] as? String } ?? []
    if let outputPath = paths[.output], outputPath.pathExtension == "o" {
        objectPaths.append(outputPath.path)
    }
    objectPaths = Array(Set(objectPaths))
    guard !objectPaths.isEmpty else { return }

    guard let target,
        let sdkPath = paths[.sdk]?.path,
        let clangPath = try xcodeDefaultToolPath(
            tool: "clang",
            sdkPath: sdkPath
        )
    else {
        fputs(
            "error: Unable to locate Xcode clang for stub object outputs.\n",
            stderr
        )
        exit(1)
    }

    let temporaryObject = FileManager.default.temporaryDirectory
        .appendingPathComponent("rules_xcodeproj-\(UUID().uuidString).o")
    defer {
        try? FileManager.default.removeItem(at: temporaryObject)
    }

    let status = try runSubProcess(
        executable: clangPath,
        args: [
            "-target", target,
            "-isysroot", sdkPath,
            "-x", "c",
            "-c", "/dev/null",
            "-o", temporaryObject.path,
        ]
    )
    guard status == 0 else {
        exit(status)
    }

    let objectData = try Data(contentsOf: temporaryObject)
    for path in objectPaths {
        let objectURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: objectURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try objectData.write(to: objectURL, options: .atomic)
    }
}

/// Create parseable metadata for Xcode's SwiftDriverJobDiscovery.
func createFrontendMetadata(
    paths: [PathKey: URL],
    moduleName: String?,
    target: String?
) throws {
    guard let referenceDependenciesPath = paths[.emitReferenceDependenciesPath]
    else {
        return
    }
    guard let target,
        let sdkPath = paths[.sdk]?.path,
        let swiftFrontendPath = try xcodeDefaultToolPath(
            tool: "swift-frontend",
            sdkPath: sdkPath
        )
    else {
        fputs(
            "error: Unable to locate Xcode swift-frontend for stub metadata.\n",
            stderr
        )
        exit(1)
    }

    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rules_xcodeproj-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let emptySource = temporaryDirectory.appendingPathComponent("empty.swift")
    let dependencies = temporaryDirectory.appendingPathComponent("empty.d")
    let diagnostics = temporaryDirectory.appendingPathComponent("empty.dia")
    let object = temporaryDirectory.appendingPathComponent("empty.o")
    let referenceDependencies = temporaryDirectory
        .appendingPathComponent("empty.swiftdeps")
    let overlay = temporaryDirectory.appendingPathComponent("overlay.json")
    try Data("\n".utf8).write(to: emptySource)
    try FileManager.default.createDirectory(
        at: object.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let primaryFile = paths[.primaryFile] ?? emptySource
    let rawOverlay: [String: Any] = [
        "version": 0,
        "case-sensitive": "false",
        "roots": [
            [
                "type": "file",
                "name": primaryFile.path,
                "external-contents": emptySource.path,
            ],
        ],
    ]
    try JSONSerialization.data(
        withJSONObject: rawOverlay,
        options: []
    ).write(to: overlay)

    let status = try runSubProcess(
        executable: swiftFrontendPath,
        args: [
            "-frontend", "-c",
            "-primary-file", primaryFile.path,
            "-vfsoverlay", overlay.path,
            "-target", target,
            "-parse-stdlib",
            "-parse-as-library",
            "-disable-objc-interop",
            "-module-name", moduleName ?? "rules_xcodeproj_stub",
            "-module-cache-path",
            temporaryDirectory.appendingPathComponent("cache").path,
            "-emit-dependencies-path", dependencies.path,
            "-emit-reference-dependencies-path", referenceDependencies.path,
            "-serialize-diagnostics-path", diagnostics.path,
            "-o", object.path,
        ]
    )
    guard status == 0 else {
        exit(status)
    }

    var outputs = [
        (referenceDependencies, referenceDependenciesPath),
    ]
    if let path = paths[.emitDependenciesPath] {
        outputs.append((dependencies, path))
    }
    if let path = paths[.serializeDiagnosticsPath] {
        outputs.append((diagnostics, path))
    }

    let fileManager = FileManager.default
    for (source, destination) in outputs {
        if fileManager.fileExists(atPath: source.path) {
            try writeData(Data(contentsOf: source), to: destination)
        } else {
            var destination = destination
            try destination.touch()
        }
    }
}

func copyBazelModuleArtifacts(
    paths: [PathKey: URL],
    includePaths: [URL],
    moduleName: String?
) throws {
    guard let moduleName, let modulePath = paths[.emitModulePath] else {
        return
    }

    let fileManager = FileManager.default
    var candidates = includePaths.map {
        $0.appendingPathComponent(moduleName + ".swiftmodule")
    }
    let environment = ProcessInfo.processInfo.environment
    if let bazelOut = environment["BAZEL_OUT"],
       let packageBinDir = environment["BAZEL_PACKAGE_BIN_DIR"] {
        let relativePackage = packageBinDir.hasPrefix("bazel-out/")
            ? String(packageBinDir.dropFirst("bazel-out/".count))
            : packageBinDir
        candidates.append(
            URL(fileURLWithPath: bazelOut)
                .appendingPathComponent(relativePackage)
                .appendingPathComponent(moduleName + ".swiftmodule")
        )
        if let outputBase = environment["BAZEL_OUTPUT_BASE"] {
            candidates.append(
                URL(fileURLWithPath: outputBase)
                    .appendingPathComponent("execroot/_main")
                    .appendingPathComponent(packageBinDir)
                    .appendingPathComponent(moduleName + ".swiftmodule")
            )
        }
    }
    if let includePath = includePaths.first,
       let binRange = modulePath.path.range(of: "/bin/") {
        let packageSuffix = String(modulePath.path[binRange.upperBound...])
            .split(separator: "/")
            .dropLast()
            .joined(separator: "/")
        candidates.append(
            includePath.deletingLastPathComponent()
                .appendingPathComponent(packageSuffix)
                .appendingPathComponent(moduleName + ".swiftmodule")
        )
    }
    guard let bazelModule = candidates.first(where: {
        fileManager.fileExists(atPath: $0.path)
    }) else {
        return
    }

    let artifactNames = [
        moduleName + ".swiftmodule",
        moduleName + ".swiftdoc",
        moduleName + ".swiftsourceinfo",
    ]
    var artifactDirectories = [
        modulePath.deletingLastPathComponent(),
    ]
    if let packageDirectory = bazelPackageBinDirectory() {
        artifactDirectories.append(packageDirectory)
    }
    for name in artifactNames {
        let source = bazelModule.deletingLastPathComponent()
            .appendingPathComponent(name)
        guard fileManager.fileExists(atPath: source.path) else { continue }
        for directory in artifactDirectories {
            let destination = directory.appendingPathComponent(name)
            try writeData(Data(contentsOf: source), to: destination)
        }
    }
}

/// Materialize outputs requested by Xcode's integrated Swift driver jobs.
func touchFrontendArtifacts(
    paths: [PathKey: URL],
    includePaths: [URL],
    moduleName: String?
) throws {
    try copyBazelModuleArtifacts(
        paths: paths,
        includePaths: includePaths,
        moduleName: moduleName
    )
    if let outputMapPath = paths[.outputFileMap], let moduleName {
        let outputMap = try readOutputFileMap(paths: paths) ?? [:]
        let objectDirectory = outputMapPath.deletingLastPathComponent()
        let frameworkDirectory = objectDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileList = outputMap.keys
            .filter { !$0.isEmpty }
            .joined(separator: "\n") + "\n"
        let fileListPath = frameworkDirectory
            .appendingPathComponent(moduleName + ".SwiftFileList")
        try fileList.data(using: .utf8)?.write(to: fileListPath, options: .atomic)
        let dependencyList = outputMap.compactMap { source, values in
            values["swift-dependencies"] as? String
                ?? values["swift-dependencies-path"] as? String
        }.joined(separator: "\n") + "\n"
        let dependencyListPath = frameworkDirectory
            .appendingPathComponent(moduleName + ".DependencyMetadataFileList")
        try dependencyList.data(using: .utf8)?.write(
            to: dependencyListPath,
            options: .atomic
        )
    }
    if var swiftmodulePath = paths[PathKey.emitModulePath] {
        var swiftdocPath = swiftmodulePath.deletingPathExtension()
            .appendingPathExtension("swiftdoc")
        var swiftsourceinfoPath = swiftmodulePath.deletingPathExtension()
            .appendingPathExtension("swiftsourceinfo")
        var swiftinterfacePath = swiftmodulePath.deletingPathExtension()
            .appendingPathExtension("swiftinterface")

        try swiftmodulePath.touch()
        try swiftdocPath.touch()
        try swiftsourceinfoPath.touch()
        try swiftinterfacePath.touch()
    }

    for key in [
        PathKey.emitABIDescriptorPath,
        .emitConstValuesPath,
        .emitDependenciesPath,
        .emitModuleDocPath,
        .emitModuleSourceInfoPath,
        .emitReferenceDependenciesPath,
        .serializeDiagnosticsPath,
    ] {
        if var path = paths[key] {
            try path.touch()
        }
    }

    if var outputPath = paths[.output], outputPath.pathExtension != "o" {
        try outputPath.touch()
    }

    if var generatedHeaderPath = paths[PathKey.emitObjCHeaderPath] {
        try generatedHeaderPath.touch()
    }
}

func writeSourceInventory(paths: [PathKey: URL], moduleName: String?) throws {
    guard let moduleName else { return }
    if paths[.outputFileMap] == nil,
       let primary = paths[.primaryFile], let object = paths[.output] {
        let objectDirectory = object.deletingLastPathComponent()
        let targetDirectory: URL
        if let range = objectDirectory.path.range(of: "/Objects-normal/") {
            targetDirectory = URL(
                fileURLWithPath: String(objectDirectory.path[..<range.lowerBound])
            )
        } else {
            targetDirectory = objectDirectory
        }
        let packageDirectory = targetDirectory.deletingLastPathComponent()
        var directories = [
            targetDirectory,
            packageDirectory,
            packageDirectory.appendingPathComponent(moduleName),
            packageDirectory.appendingPathComponent(moduleName + ".library"),
        ]
        let bazelPackageDirectory = bazelPackageBinDirectory()
        if let bazelPackageDirectory {
            directories.append(contentsOf: [
                bazelPackageDirectory,
                bazelPackageDirectory.appendingPathComponent(moduleName + "_objs"),
                bazelPackageDirectory
                    .appendingPathComponent(moduleName + ".library_objs"),
            ])
        }
        let sourceList = Data((primary.path + "\n").utf8)
        let dependencyList = Data((
            paths[.emitReferenceDependenciesPath]?.path ?? ""
        + "\n").utf8)
        for directory in directories {
            let listPath = directory.appendingPathComponent(moduleName + ".SwiftFileList")
            try writeData(sourceList, to: listPath)
            let dependencyPath = directory.appendingPathComponent(moduleName + ".DependencyMetadataFileList")
            if paths[.emitReferenceDependenciesPath] != nil {
                try writeData(dependencyList, to: dependencyPath)
            }
        }
        var linkDirectories = [
            targetDirectory,
            packageDirectory,
            packageDirectory.appendingPathComponent(moduleName),
            packageDirectory.appendingPathComponent(moduleName + ".library"),
        ]
        if let bazelPackageDirectory {
            linkDirectories.append(contentsOf: [
                bazelPackageDirectory,
                bazelPackageDirectory.appendingPathComponent(moduleName + "_objs"),
                bazelPackageDirectory
                    .appendingPathComponent(moduleName + ".library_objs"),
            ])
        }
        let objectList = Data((object.path + "\n").utf8)
        for directory in linkDirectories {
            let linkList = directory.appendingPathComponent(moduleName + ".LinkFileList")
            try writeData(objectList, to: linkList)
        }
        let objectName = object.lastPathComponent
        var objectDirectories = [
            packageDirectory.appendingPathComponent(moduleName + ".library_objs"),
            packageDirectory
                .appendingPathComponent(moduleName)
                .appendingPathComponent("Objects-normal/arm64"),
            packageDirectory
                .appendingPathComponent(moduleName + ".library")
                .appendingPathComponent("Objects-normal/arm64"),
        ]
        if let bazelPackageDirectory {
            objectDirectories.append(contentsOf: [
                bazelPackageDirectory.appendingPathComponent(moduleName + "_objs"),
                bazelPackageDirectory
                    .appendingPathComponent(moduleName + ".library_objs"),
            ])
        }
        for directory in objectDirectories {
            if FileManager.default.fileExists(atPath: object.path) {
                try copyFileOverwriting(
                    source: object,
                    destination: directory.appendingPathComponent(objectName)
                )
            }
        }
        return
    }
    guard let outputMapPath = paths[.outputFileMap] else { return }
    let outputMap = try readOutputFileMap(paths: paths) ?? [:]
    let frameworkDirectory = outputMapPath.deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sources = outputMap.keys.filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
    let dependencies = outputMap.compactMap { _, values in
        values["swift-dependencies"] as? String
            ?? values["swift-dependencies-path"] as? String
    }.joined(separator: "\n") + "\n"
    var directories = [
        frameworkDirectory,
        frameworkDirectory.deletingLastPathComponent(),
        frameworkDirectory.deletingLastPathComponent()
            .appendingPathComponent(moduleName),
        frameworkDirectory.deletingLastPathComponent()
            .appendingPathComponent(moduleName + ".library"),
    ]
    if let bazelPackageDirectory = bazelPackageBinDirectory() {
        directories.append(contentsOf: [
            bazelPackageDirectory,
            bazelPackageDirectory.appendingPathComponent(moduleName + "_objs"),
        ])
    }
    for directory in directories {
        try writeData(
            Data(sources.utf8),
            to: directory.appendingPathComponent(moduleName + ".SwiftFileList")
        )
        try writeData(
            Data(dependencies.utf8),
            to: directory.appendingPathComponent(moduleName + ".DependencyMetadataFileList")
        )
    }
}

func runSubProcess(executable: String, args: [String]) throws -> Int32 {
    let task = Process()
    task.launchPath = executable
    task.arguments = args
    try task.run()
    task.waitUntilExit()
    return task.terminationStatus
}

func handleXcodePreviewThunk(args: [String], paths: [PathKey: URL]) throws -> Never {
    guard let sdkPath = paths[PathKey.sdk]?.path else {
        fputs(
            "error: No such argument '-sdk'. Using /usr/bin/swiftc.",
            stderr
        )
        exit(1)
    }

    guard let swiftcPath = try xcodeDefaultToolPath(
        tool: "swiftc",
        sdkPath: sdkPath
    )
    else {
        fputs(
            """
error: Failed to parse DEVELOPER_DIR from '-sdk'. Using /usr/bin/swiftc.
""",
            stderr
        )
        exit(1)
    }

    try exit(runSubProcess(
        executable: swiftcPath,
        args: Array(args.dropFirst())
    ))
}

// MARK: - Main

let args = CommandLine.arguments
// Xcode 16.0 Beta 3 began using "--version" over "-v". Support both.
if args.count == 2, args.last == "--version" || args.last == "-v" {
    let environment = ProcessInfo.processInfo.environment
    let developerDir: Substring

    if let value = environment["DEVELOPER_DIR"], !value.isEmpty {
        developerDir = value[...]
    } else {
        // Custom toolchains can prepend their own `usr/bin` to `PATH`, so
        // search for Xcode's developer bin directory instead of assuming it is
        // first.
        guard let xcodeBinPath = environment["PATH"]?.split(
            separator: ":"
        ).first(where: {
            $0.hasSuffix("/Contents/Developer/usr/bin")
        }) else {
            fputs("error: DEVELOPER_DIR and Xcode based PATH not set", stderr)
            exit(1)
        }

        // /Applications/Xcode.app/Contents/Developer/usr/bin ->
        // /Applications/Xcode.app/Contents/Developer
        developerDir = xcodeBinPath.dropLast(8)
    }

    let swiftcPath = """
\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
"""

    // args.last allows passing in -v (Xcode < 16b3) and --version (>= 16b3)
    try exit(runSubProcess(executable: swiftcPath, args: [args.last!]))
}

let (
    isPreviewThunk,
    isWMO,
    paths,
    includePaths,
    moduleName,
    target
) = try await processArgs(args)

guard !isPreviewThunk else {
    // Pass through for Xcode Preview thunk compilation
    try handleXcodePreviewThunk(args: args, paths: paths)
}

try touchDepsFiles(isWMO: isWMO, paths: paths)
try createFrontendMetadata(
    paths: paths,
    moduleName: moduleName,
    target: target
)
try createObjectFiles(paths: paths, target: target)
try writeSourceInventory(paths: paths, moduleName: moduleName)
try touchFrontendArtifacts(
    paths: paths,
    includePaths: includePaths,
    moduleName: moduleName
)
