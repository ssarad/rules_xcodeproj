import CustomDump
import ToolCommon
import XCTest

@testable import pbxnativetargets
@testable import PBXProj

class CreateLinkArtifactObjectsTests: XCTestCase {
    func testFileTypes() {
        let createSubIdentifier = Generator.CreateBuildFileSubIdentifier {
            path,
            type,
            shard,
            _ in
            return .init(
                shard: "\(shard)",
                type: type,
                path: path,
                hash: type.rawValue
            )
        }
        let createObjects = Generator.CreateLinkArtifactObjects()

        let cases = [
            ("bazel-out/bin/libA.a", "archive.ar"),
            ("bazel-out/bin/libB.dylib", "compiled.mach-o.dylib"),
            ("bazel-out/bin/C.framework", "wrapper.framework"),
        ]

        for (path, fileType) in cases {
            let result = createObjects(
                createBuildFileSubIdentifier: createSubIdentifier,
                path: BazelPath(path),
                shard: 7
            )

            XCTAssertEqual(result.objects.count, 2)
            XCTAssertTrue(
                result.objects[0].content.contains(
                    "lastKnownFileType = \(fileType)"
                )
            )
            XCTAssertTrue(
                result.objects[0].content.contains("sourceTree = SOURCE_ROOT")
            )
            XCTAssertTrue(
                result.objects[1].content.contains("isa = PBXBuildFile")
            )
        }
    }
}
