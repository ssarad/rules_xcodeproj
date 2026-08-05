import PBXProj

extension Generator {
    struct CreateBazelIntegrationBuildPhaseObject {
        private let callable: Callable

        /// - Parameters:
        ///   - callable: The function that will be called in
        ///     `callAsFunction()`.
        init(callable: @escaping Callable = Self.defaultCallable) {
            self.callable = callable
        }

        /// Creates the Bazel integration build phase `Object` for a target.
        func callAsFunction(
            subIdentifier: Identifiers.Targets.SubIdentifier,
            productType: PBXProductType,
            usesInfoPlist: Bool
        ) -> Object? {
            return callable(
                /*subIdentifier:*/ subIdentifier,
                /*productType:*/ productType,
                /*usesInfoPlist:*/ usesInfoPlist
            )
        }
    }
}

// MARK: - CreateBazelIntegrationBuildPhaseObject.Callable

extension Generator.CreateBazelIntegrationBuildPhaseObject {
    typealias Callable = (
        _ subIdentifier: Identifiers.Targets.SubIdentifier,
        _ productType: PBXProductType,
        _ usesInfoPlist: Bool
    ) -> Object?

    static func defaultCallable(
        subIdentifier: Identifiers.Targets.SubIdentifier,
        productType: PBXProductType,
        usesInfoPlist: Bool
    ) -> Object? {
        guard productType != .resourceBundle else {
            return nil
        }

        let shellScript = #"""
set -euo pipefail

if [[ "$ACTION" == "indexbuild" ]]; then
  cd "$SRCROOT"

  "$CENTRALIZED_TOOLS_DIR/generate_index_build_bazel_dependencies.sh"
else
  "$CENTRALIZED_TOOLS_DIR/copy_outputs.sh" \
    "_BazelForcedCompile_.swift" \
    "\#(productType.rsyncExcludeFile)"
fi

"""#

        let infoPlistInputPath: String
        if usesInfoPlist {
            infoPlistInputPath = #"""
				"$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)",

"""#
        } else {
            infoPlistInputPath = ""
        }

        // The tabs for indenting are intentional
        let content = #"""
{
			isa = PBXShellScriptBuildPhase;
			alwaysOutOfDate = 1;
			buildActionMask = 2147483647;
			files = (
			);
			inputPaths = (
\#(infoPlistInputPath)\#
			);
			name = \#(BuildPhase.bazelIntegration.name.pbxProjEscaped);
			outputPaths = (
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = \#(shellScript.pbxProjEscaped);
			showEnvVarsInLog = 0;
		}
"""#

        return Object(
            identifier: Identifiers.Targets.buildPhase(
                .bazelIntegration,
                subIdentifier: subIdentifier
            ),
            content: content
        )
    }
}

private extension PBXProductType {
    var rsyncExcludeFile: String {
        switch self {
        case .application,
            .messagesApplication,
            .onDemandInstallCapableApplication,
            .watch2AppContainer:
            return "$CENTRALIZED_TOOLS_DIR/app.exclude.rsynclist"
        case .framework:
            return "$CENTRALIZED_TOOLS_DIR/framework.exclude.rsynclist"
        case .unitTestBundle,
            .uiTestBundle:
            return "$CENTRALIZED_TOOLS_DIR/xctest.exclude.rsynclist"
        case .appExtension,
            .extensionKitExtension,
            .intentsServiceExtension,
            .messagesExtension,
            .tvExtension,
            .watch2Extension:
            return "$CENTRALIZED_TOOLS_DIR/appex.exclude.rsynclist"
        case .watch2App:
            return "$CENTRALIZED_TOOLS_DIR/watchos2_app.exclude.rsynclist"
        case .stickerPack,
             .xcodeExtension,
             .resourceBundle,
             .bundle,
             .ocUnitTestBundle,
             .staticFramework,
             .xcFramework,
             .dynamicLibrary,
             .staticLibrary,
             .driverExtension,
             .instrumentsPackage,
             .metalLibrary,
             .systemExtension,
             .commandLineTool,
             .xpcService:
            return ""
        }
    }
}
