import PBXProj
import ToolCommon

extension Generator {
    struct CreateLinkArtifactObjects {
        func callAsFunction(
            createBuildFileSubIdentifier: CreateBuildFileSubIdentifier,
            path: BazelPath,
            shard: UInt8
        ) -> (
            buildFileIdentifier: String,
            objects: [Object]
        ) {
            let referenceSubIdentifier = createBuildFileSubIdentifier(
                path,
                type: .linkArtifactReference,
                shard: shard
            )
            let buildFileSubIdentifier = createBuildFileSubIdentifier(
                path,
                type: .linkArtifact,
                shard: shard
            )
            let referenceIdentifier = Identifiers.BuildFiles.id(
                subIdentifier: referenceSubIdentifier
            )
            let buildFileIdentifier = Identifiers.BuildFiles.id(
                subIdentifier: buildFileSubIdentifier
            )

            let fileType: String
            if path.path.hasSuffix(".framework") {
                fileType = "wrapper.framework"
            } else if path.path.hasSuffix(".dylib") {
                fileType = "compiled.mach-o.dylib"
            } else {
                fileType = "archive.ar"
            }

            let name = String(path.path.split(separator: "/").last!)
            let reference = Object(
                identifier: referenceIdentifier,
                content: #"""
{isa = PBXFileReference; lastKnownFileType = \#(fileType); name = \#(
    name.pbxProjEscaped
); path = \#(path.path.pbxProjEscaped); sourceTree = SOURCE_ROOT; }
"""#
            )
            let buildFile = Object(
                identifier: buildFileIdentifier,
                content: #"""
{isa = PBXBuildFile; fileRef = \#(referenceIdentifier); }
"""#
            )

            return (buildFileIdentifier, [reference, buildFile])
        }
    }
}
