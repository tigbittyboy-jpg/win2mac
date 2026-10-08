#!/usr/bin/env python3
"""Rebuild Bridge.xcodeproj deterministically; no third-party generator dependency."""
from pathlib import Path
import hashlib
import json
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
OBJECTS = {}


def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def add(object_name, isa, **fields):
    key = identifier(object_name)
    OBJECTS[key] = {"isa": isa, **fields}
    return key


def encode(value):
    if isinstance(value, dict):
        return "{\n" + "\n".join(f"{json.dumps(str(k))} = {encode(v)};" for k, v in value.items()) + "\n}"
    if isinstance(value, list):
        return "(\n" + "\n".join(encode(v) + "," for v in value) + "\n)"
    if isinstance(value, int):
        return str(value)
    return json.dumps(value)


def configuration_list(name, settings):
    configs = []
    for mode in ("Debug", "Release"):
        per_mode = dict(settings)
        per_mode["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if mode == "Debug" else "-O"
        if mode == "Debug":
            per_mode["ENABLE_TESTABILITY"] = "YES"
            per_mode["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) DEBUG"
        configs.append(add(name + mode, "XCBuildConfiguration", buildSettings=per_mode, name=mode))
    return add(name + "Configurations", "XCConfigurationList", buildConfigurations=configs,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


common = {"SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0", "SWIFT_VERSION": "6.0",
          "SWIFT_STRICT_CONCURRENCY": "complete", "ARCHS": "arm64", "ONLY_ACTIVE_ARCH": "NO",
          "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
          "SUPPORTED_PLATFORMS": "macosx", "CODE_SIGN_IDENTITY": "-",
          "CODE_SIGN_STYLE": "Manual", "ENABLE_USER_SCRIPT_SANDBOXING": "YES"}
product_refs = {}
groups = []
source_phases = {}
for target, folder, extension, file_type in [
    ("BridgeCore", "Sources/BridgeCore", "a", "archive.ar"),
    ("Bridge", "Sources/BridgeApp", "app", "wrapper.application"),
    ("BridgeCoreTests", "Tests/BridgeCoreTests", "xctest", "wrapper.cfbundle"),
]:
    files, builds = [], []
    for path in sorted((ROOT / folder).glob("*.swift")):
        relative = path.relative_to(ROOT).as_posix()
        ref = add(relative, "PBXFileReference", lastKnownFileType="sourcecode.swift",
                  path=relative, sourceTree="SOURCE_ROOT")
        files.append(ref)
        builds.append(add(relative + "Build", "PBXBuildFile", fileRef=ref))
    groups.append(add(target + "Group", "PBXGroup", name=target, children=files, sourceTree="<group>"))
    source_phases[target] = add(target + "Sources", "PBXSourcesBuildPhase", buildActionMask=2147483647,
                               files=builds, runOnlyForDeploymentPostprocessing=0)
    product_refs[target] = add(target + "Product", "PBXFileReference", explicitFileType=file_type,
                               includeInIndex=0, path=("lib" if target == "BridgeCore" else "") + target + "." + extension,
                               sourceTree="BUILT_PRODUCTS_DIR")

project_id = identifier("Project")
targets = []
for target, kind in [("BridgeCore", "library.static"), ("Bridge", "application"), ("BridgeCoreTests", "bundle.unit-test")]:
    settings = dict(common)
    settings.update({"PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER": "org.bridge-launcher." + target,
                     "GENERATE_INFOPLIST_FILE": "YES", "CURRENT_PROJECT_VERSION": "6",
                     "MARKETING_VERSION": "0.1.0"})
    linked = []
    dependencies = []
    phases = [source_phases[target]]
    if target != "BridgeCore":
        link = add(target + "CoreLink", "PBXBuildFile", fileRef=product_refs["BridgeCore"])
        linked.append(link)
        proxy = add(target + "CoreProxy", "PBXContainerItemProxy", containerPortal=project_id,
                    proxyType=1, remoteGlobalIDString=identifier("BridgeCoreTarget"), remoteInfo="BridgeCore")
        dependencies.append(add(target + "CoreDependency", "PBXTargetDependency",
                                target=identifier("BridgeCoreTarget"), targetProxy=proxy))
        settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/../Frameworks",
                                               "@loader_path/../Frameworks"]
    if target == "BridgeCore":
        # Keep the Swift module boundary, but link our code into each consumer.
        # Ad hoc previews have no Apple Team ID; a separate non-platform dylib
        # can be rejected by hardened-runtime library validation after download.
        settings.update({"DEFINES_MODULE": "YES", "SKIP_INSTALL": "YES",
                         "MACH_O_TYPE": "staticlib", "EXECUTABLE_PREFIX": "lib",
                         "GENERATE_INFOPLIST_FILE": "NO"})
    elif target == "Bridge":
        settings.update({"ENABLE_APP_SANDBOX": "NO", "ENABLE_HARDENED_RUNTIME": "YES",
                         "INFOPLIST_KEY_CFBundleDisplayName": "Bridge",
                         "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.utilities",
                         "INFOPLIST_KEY_NSPrincipalClass": "NSApplication"})
    else:
        settings["SKIP_INSTALL"] = "YES"
    phases.append(add(target + "Frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
                      files=linked, runOnlyForDeploymentPostprocessing=0))
    targets.append(add(target + "Target", "PBXNativeTarget", name=target, productName=target,
                        buildConfigurationList=configuration_list(target, settings), buildPhases=phases,
                        buildRules=[], dependencies=dependencies, productReference=product_refs[target],
                        productType="com.apple.product-type." + kind))

products = add("Products", "PBXGroup", children=list(product_refs.values()), name="Products", sourceTree="<group>")
main = add("MainGroup", "PBXGroup", children=groups + [products], sourceTree="<group>")
add("Project", "PBXProject", attributes={"LastUpgradeCheck": "1600", "LastSwiftUpdateCheck": "1600",
                                       "BuildIndependentTargetsInParallel": "YES"},
    buildConfigurationList=configuration_list("Project", common), compatibilityVersion="Xcode 14.0",
    developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=main,
    productRefGroup=products, projectDirPath="", projectRoot="", targets=targets)
project = ROOT / "Bridge.xcodeproj"
project.mkdir(exist_ok=True)
(project / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode({
    "archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": OBJECTS, "rootObject": project_id
}) + "\n")


def reference(parent, target):
    extension = "xctest" if target.endswith("Tests") else "app"
    return ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary",
                         BlueprintIdentifier=identifier(target + "Target"), BuildableName=target + "." + extension,
                         BlueprintName=target, ReferencedContainer="container:Bridge.xcodeproj")


scheme = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.3")
build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
entries = ET.SubElement(build, "BuildActionEntries")
for target in ("Bridge", "BridgeCoreTests"):
    app = target == "Bridge"
    entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES" if app else "NO",
                          buildForProfiling="YES" if app else "NO", buildForArchiving="YES" if app else "NO",
                          buildForAnalyzing="YES")
    reference(entry, target)
test = ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                     selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", shouldUseLaunchSchemeArgsEnv="YES")
testables = ET.SubElement(test, "Testables")
reference(ET.SubElement(testables, "TestableReference", skipped="NO"), "BridgeCoreTests")
launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug",
                       selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                       selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0",
                       useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO",
                       debugDocumentVersioning="YES", debugServiceExtension="internal", allowLocationSimulation="YES")
reference(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"), "Bridge")
profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES",
                        savedToolIdentifier="", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
reference(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"), "Bridge")
ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
ET.indent(scheme, space="  ")
scheme_path = project / "xcshareddata/xcschemes/Bridge.xcscheme"
scheme_path.parent.mkdir(parents=True, exist_ok=True)
ET.ElementTree(scheme).write(scheme_path, encoding="UTF-8", xml_declaration=True)
print(f"Generated {project.name} with {len(targets)} targets and a shared Bridge scheme.")
