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

        let normalizeFrameworkForPreviews: String
        if productType == .framework {
            normalizeFrameworkForPreviews = #"""

target_build_dir="${TARGET_BUILD_DIR:-${BUILT_PRODUCTS_DIR:-}}"
wrapper_name="${WRAPPER_NAME:-${PRODUCT_NAME:-}.framework}"
executable_name="${EXECUTABLE_NAME:-${PRODUCT_NAME:-}}"
framework_dir="$target_build_dir/$wrapper_name"
if [[ -d "$framework_dir" && -n "$executable_name" ]]; then
  framework_version="${FRAMEWORK_VERSION:-A}"
  version_dir="$framework_dir/Versions/$framework_version"
  mkdir -p "$version_dir/Resources"

  if [[ -f "$framework_dir/Info.plist" ]]; then
    cp -f "$framework_dir/Info.plist" "$version_dir/Resources/Info.plist"
  fi

  if [[ -f "$framework_dir/$executable_name" ]]; then
    cp -f "$framework_dir/$executable_name" "$version_dir/$executable_name"
  fi
fi
"""#
        } else {
            normalizeFrameworkForPreviews = ""
        }

        let shellScript = #"""
set -euo pipefail

if [[ "$ACTION" == "indexbuild" ]]; then
  cd "$SRCROOT"

  "$BAZEL_INTEGRATION_DIR/generate_index_build_bazel_dependencies.sh"
else
  "$BAZEL_INTEGRATION_DIR/copy_outputs.sh" \
    "_BazelForcedCompile_.swift" \
    "\#(productType.rsyncExcludeFile)"
\#(normalizeFrameworkForPreviews)
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
            return "$BAZEL_INTEGRATION_DIR/app.exclude.rsynclist"
        case .framework:
            return "$BAZEL_INTEGRATION_DIR/framework.exclude.rsynclist"
        case .unitTestBundle,
            .uiTestBundle:
            return "$BAZEL_INTEGRATION_DIR/xctest.exclude.rsynclist"
        case .appExtension,
            .extensionKitExtension,
            .intentsServiceExtension,
            .messagesExtension,
            .tvExtension,
            .watch2Extension:
            return "$BAZEL_INTEGRATION_DIR/appex.exclude.rsynclist"
        case .watch2App:
            return "$BAZEL_INTEGRATION_DIR/watchos2_app.exclude.rsynclist"
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
