import PBXProj

extension Generator {
    struct CreateLinkBinaryWithLibrariesBuildPhaseObject {
        func callAsFunction(
            subIdentifier: Identifiers.Targets.SubIdentifier,
            buildFileIdentifiers: [String]
        ) -> Object {
            let content = #"""
{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
\#(buildFileIdentifiers.map { "\t\t\t\t\($0),\n" }.joined())\#
			);
			runOnlyForDeploymentPostprocessing = 0;
		}
"""#

            return Object(
                identifier: Identifiers.Targets.buildPhase(
                    .linkBinaryWithLibraries,
                    subIdentifier: subIdentifier
                ),
                content: content
            )
        }
    }
}
