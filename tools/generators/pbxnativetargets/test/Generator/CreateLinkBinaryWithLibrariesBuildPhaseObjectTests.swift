import CustomDump
import XCTest

@testable import pbxnativetargets
@testable import PBXProj

class CreateLinkBinaryWithLibrariesBuildPhaseObjectTests: XCTestCase {
    func test() {
        let subIdentifier = Identifiers.Targets.SubIdentifier(
            shard: "A_SHARD",
            hash: "A_HASH"
        )

        let object = Generator.CreateLinkBinaryWithLibrariesBuildPhaseObject()(
            subIdentifier: subIdentifier,
            buildFileIdentifiers: [
                "STATIC /* libStatic.a in Frameworks */",
                "DYNAMIC /* libDynamic.dylib in Frameworks */",
            ]
        )

        XCTAssertNoDifference(
            object,
            Object(
                identifier: #"""
A_SHARD00A_HASH000000000009 /* Frameworks */
"""#,
                content: #"""
{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				STATIC /* libStatic.a in Frameworks */,
				DYNAMIC /* libDynamic.dylib in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}
"""#
            )
        )
    }
}
