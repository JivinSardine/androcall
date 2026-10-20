#!/usr/bin/env python3
"""Build the androcall macOS application without Xcode.

The build uses ``swiftc`` directly against the macOS SDK and assembles a
genuine ``.app`` bundle by hand. This keeps the build working on any macOS
host that has the Command Line Tools installed, on both Intel and Apple
Silicon, and it makes the macOS 12 deployment target a *compile-time*
constraint: any accidental use of an API introduced after macOS 12 is a build
error rather than a runtime crash.

Usage:
    python3 scripts/build_macos.py                 # build for the host arch
    python3 scripts/build_macos.py --arch arm64   # cross-build for arm64
    python3 scripts/build_macos.py --arch both    # universal binary
    python3 scripts/build_macos.py --dmg          # also build a .dmg
    python3 scripts/build_macos.py --clean
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CORE_DIR = os.path.join(REPO, "macos", "AndroCallCore")
APP_DIR = os.path.join(REPO, "macos", "AndroCall")
RESOURCES_DIR = os.path.join(REPO, "macos", "Resources")
BUILD_DIR = os.path.join(REPO, "build", "macos")
DIST_DIR = os.path.join(REPO, "dist")

APP_NAME = "androcall"
BUNDLE_ID = "dev.androcall.mac"
MARKETING_VERSION = "0.1.0"
BUILD_NUMBER = "1"
MIN_MACOS = "12.0"
DEPLOYMENT_TARGET = "macos12.0"

SWIFT_SOURCES_CORE = [
    "ProtocolConstants.swift",
    "Crypto.swift",
    "SessionKeys.swift",
    "Frame.swift",
    "CanonicalJSON.swift",
    "Message.swift",
    "Models.swift",
    "PhoneNumber.swift",
    "Transport.swift",
    "Session.swift",
]

SWIFT_SOURCES_APP = [
    "AndroCallApp.swift",
    "AppModel.swift",
    "BluetoothManager.swift",
    "ContactStore.swift",
    "NotificationService.swift",
    "SettingsStore.swift",
    "Logging.swift",
    "Views/WelcomeView.swift",
    "Views/DashboardView.swift",
    "Views/ContactsView.swift",
    "Views/ContactDetailView.swift",
    "Views/DialPadView.swift",
    "Views/CallView.swift",
    "Views/SettingsView.swift",
    "Views/DiagnosticsView.swift",
    "Views/DesignSystem.swift",
]


def log(message: str) -> None:
    print(f"[build] {message}", flush=True)


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    log(" ".join(command[:6]) + (" ..." if len(command) > 6 else ""))
    return subprocess.run(command, check=True, **kwargs)


def sdk_path() -> str:
    return subprocess.run(
        ["xcrun", "--show-sdk-path"], check=True, capture_output=True, text=True
    ).stdout.strip()


def swift_version() -> str:
    return subprocess.run(
        ["swift", "--version"], check=True, capture_output=True, text=True
    ).stdout.splitlines()[0]


def target_triple(arch: str) -> str:
    return f"{arch}-apple-{DEPLOYMENT_TARGET}"


def swift_sources(directory: str, names: list[str]) -> list[str]:
    paths = []
    for name in names:
        path = os.path.join(directory, name)
        if not os.path.exists(path):
            raise SystemExit(f"missing source file: {path}")
        paths.append(path)
    return paths


def build_core(arch: str, sdk: str, out_dir: str) -> tuple[str, str]:
    """Compile AndroCallCore into a module and a static library."""
    module_dir = os.path.join(out_dir, "core")
    os.makedirs(module_dir, exist_ok=True)
    swift_module = os.path.join(module_dir, "AndroCallCore.swiftmodule")
    library = os.path.join(module_dir, "libAndroCallCore.a")

    sources = swift_sources(CORE_DIR, SWIFT_SOURCES_CORE)
    command = [
        "swiftc",
        "-sdk", sdk,
        "-target", target_triple(arch),
        "-swift-version", "5",
        "-emit-module",
        "-emit-module-path", swift_module,
        "-emit-library",
        "-static",
        "-o", library,
        "-module-name", "AndroCallCore",
        "-O",
        "-whole-module-optimization",
        *sources,
    ]
    run(command)
    return swift_module, library


def build_app(arch: str, sdk: str, out_dir: str, core_module: str, core_library: str) -> str:
    """Compile the application executable."""
    os.makedirs(out_dir, exist_ok=True)
    executable = os.path.join(out_dir, APP_NAME)

    sources = swift_sources(APP_DIR, SWIFT_SOURCES_APP)
    command = [
        "swiftc",
        "-sdk", sdk,
        "-target", target_triple(arch),
        "-swift-version", "5",
        "-module-name", "AndroCall",
        "-I", os.path.dirname(core_module),
        "-L", os.path.dirname(core_library),
        "-lAndroCallCore",
        "-framework", "SwiftUI",
        "-framework", "AppKit",
        "-framework", "CoreBluetooth",
        "-framework", "UserNotifications",
        "-framework", "ServiceManagement",
        "-framework", "AVFoundation",
        "-framework", "CryptoKit",
        "-O",
        "-o", executable,
        *sources,
    ]
    run(command)
    return executable


def write_entitlements(path: str) -> None:
    """Write the app's entitlements.

    ``com.apple.security.device.bluetooth`` is required to talk to Bluetooth
    devices. The app is not sandboxed: it keeps a background service alive so
    that incoming calls still arrive when the window is closed.
    """
    entitlements = {
        "com.apple.security.device.bluetooth": True,
        "com.apple.security.app-sandbox": False,
    }
    with open(path, "wb") as handle:
        plistlib.dump(entitlements, handle)


def app_info_plist() -> dict:
    return {
        "CFBundleName": APP_NAME,
        "CFBundleDisplayName": "androcall",
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleVersion": BUILD_NUMBER,
        "CFBundleShortVersionString": MARKETING_VERSION,
        "CFBundlePackageType": "APPL",
        "CFBundleSignature": "????",
        "CFBundleExecutable": APP_NAME,
        "CFBundleIconFile": "AppIcon",
        "LSMinimumSystemVersion": MIN_MACOS,
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
        "LSApplicationCategoryType": "public.app-category.utilities",
        "NSBluetoothAlwaysUsageDescription": (
            "androcall uses Bluetooth to talk to your Android phone so you can make "
            "calls, answer incoming calls and browse your contacts from your Mac."
        ),
        "NSMicrophoneUsageDescription": (
            "androcall does not record audio. This permission is requested only if "
            "you choose to use your Mac's microphone while a call is active."
        ),
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
        "CFBundleDocumentTypes": [],
    }


def assemble_bundle(arch: str, executable: str, bundle_root: str) -> str:
    """Assemble a genuine .app bundle around the executable."""
    contents = os.path.join(bundle_root, "Contents")
    macos = os.path.join(contents, "MacOS")
    resources = os.path.join(contents, "Resources")
    os.makedirs(macos, exist_ok=True)
    os.makedirs(resources, exist_ok=True)

    shutil.copy2(executable, os.path.join(macos, APP_NAME))

    with open(os.path.join(contents, "Info.plist"), "wb") as handle:
        plistlib.dump(app_info_plist(), handle)

    with open(os.path.join(contents, "PkgInfo"), "w", encoding="utf-8") as handle:
        handle.write("APPL????")

    icon = os.path.join(RESOURCES_DIR, "AppIcon.icns")
    if os.path.exists(icon):
        shutil.copy2(icon, os.path.join(resources, "AppIcon.icns"))

    # The entitlements file must live outside the bundle: codesign refuses to
    # sign a bundle that contains an un-signable subcomponent.
    entitlements = os.path.join(BUILD_DIR, f"{APP_NAME}-{arch}.entitlements.plist")
    write_entitlements(entitlements)

    # Ad-hoc signature so the bundle runs on the build machine. A Developer ID
    # signature is applied by scripts/sign_and_notarize.py when credentials are
    # available; this build is explicitly unsigned and is documented as such.
    subprocess.run(
        [
            "codesign",
            "--force",
            "--sign",
            "-",
            "--entitlements",
            entitlements,
            "--options",
            "runtime",
            bundle_root,
        ],
        check=True,
        capture_output=True,
    )
    return bundle_root


def make_dmg(bundle_root: str, arch: str) -> str:
    os.makedirs(DIST_DIR, exist_ok=True)
    dmg = os.path.join(DIST_DIR, f"{APP_NAME}-macOS-{arch}.dmg")
    if os.path.exists(dmg):
        os.remove(dmg)
    staging = os.path.join(BUILD_DIR, f"dmg-{arch}")
    if os.path.exists(staging):
        shutil.rmtree(staging)
    os.makedirs(staging)
    shutil.copytree(bundle_root, os.path.join(staging, f"{APP_NAME}.app"))
    os.symlink("/Applications", os.path.join(staging, "Applications"))
    subprocess.run(
        [
            "hdiutil", "create",
            "-volname", f"androcall {MARKETING_VERSION}",
            "-srcfolder", staging,
            "-ov", "-format", "UDZO", dmg,
        ],
        check=True,
        capture_output=True,
    )
    shutil.rmtree(staging)
    log(f"created {dmg}")
    return dmg


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", default="host", choices=["host", "x86_64", "arm64", "both"])
    parser.add_argument("--dmg", action="store_true", help="also produce a .dmg installer")
    parser.add_argument("--clean", action="store_true", help="remove build artefacts first")
    parser.add_argument("--version", action="store_true", help="print the toolchain version")
    args = parser.parse_args()

    if args.version:
        print(swift_version())
        return 0

    if args.clean and os.path.exists(BUILD_DIR):
        shutil.rmtree(BUILD_DIR)

    host_arch = subprocess.run(
        ["uname", "-m"], check=True, capture_output=True, text=True
    ).stdout.strip()
    if args.arch == "host":
        arches = [host_arch]
    elif args.arch == "both":
        arches = ["x86_64", "arm64"]
    else:
        arches = [args.arch]

    sdk = sdk_path()
    log(f"toolchain: {swift_version()}")
    log(f"sdk: {sdk}")
    log(f"architectures: {', '.join(arches)}")

    os.makedirs(BUILD_DIR, exist_ok=True)

    for arch in arches:
        out_dir = os.path.join(BUILD_DIR, arch)
        core_module, core_library = build_core(arch, sdk, out_dir)
        executable = build_app(arch, sdk, out_dir, core_module, core_library)
        bundle = os.path.join(BUILD_DIR, f"{APP_NAME}-{arch}.app")
        if os.path.exists(bundle):
            shutil.rmtree(bundle)
        assemble_bundle(arch, executable, bundle)
        log(f"assembled {bundle}")
        if args.dmg:
            make_dmg(bundle, arch)

    if len(arches) == 2:
        universal = os.path.join(BUILD_DIR, f"{APP_NAME}-universal.app")
        if os.path.exists(universal):
            shutil.rmtree(universal)
        x86 = os.path.join(BUILD_DIR, "androcall-x86_64.app", "Contents", "MacOS", APP_NAME)
        arm = os.path.join(BUILD_DIR, "androcall-arm64.app", "Contents", "MacOS", APP_NAME)
        universal_binary = os.path.join(
            BUILD_DIR, "androcall-universal.app", "Contents", "MacOS", APP_NAME
        )
        os.makedirs(os.path.dirname(universal_binary), exist_ok=True)
        subprocess.run(["lipo", "-create", x86, arm, "-output", universal_binary], check=True)
        shutil.copytree(
            os.path.join(BUILD_DIR, "androcall-arm64.app", "Contents", "Resources"),
            os.path.join(os.path.dirname(universal_binary), "..", "Resources"),
            dirs_exist_ok=True,
        )
        shutil.copy2(
            os.path.join(BUILD_DIR, "androcall-arm64.app", "Contents", "Info.plist"),
            os.path.join(os.path.dirname(universal_binary), "..", "Info.plist"),
        )
        shutil.copy2(
            os.path.join(BUILD_DIR, "androcall-arm64.app", "Contents", "PkgInfo"),
            os.path.join(os.path.dirname(universal_binary), "..", "PkgInfo"),
        )
        entitlements = os.path.join(BUILD_DIR, f"{APP_NAME}-universal.entitlements.plist")
        write_entitlements(entitlements)
        subprocess.run(
            [
                "codesign", "--force", "--sign", "-",
                "--entitlements", entitlements,
                "--options", "runtime",
                universal,
            ],
            check=True,
            capture_output=True,
        )
        log(f"assembled {universal}")
        if args.dmg:
            make_dmg(universal, "Universal")

    log("build complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
