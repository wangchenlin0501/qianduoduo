#!/usr/bin/env python3
"""Check local submission resources without uploading or changing Apple accounts."""

import argparse
import hashlib
import json
import plistlib
import re
import struct
import subprocess
from pathlib import Path
from xml.etree import ElementTree


ROOT = Path(__file__).resolve().parents[1]


def check(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")


def plist(path):
    with path.open("rb") as file:
        return plistlib.load(file)


def manifest(path, required):
    value = plist(path)
    check(value.get("NSPrivacyTracking") is False, f"Tracking must be false: {path.name}")
    check(value.get("NSPrivacyTrackingDomains") == [], "Unexpected tracking domains")
    check(value.get("NSPrivacyCollectedDataTypes") == [], "Reassess data collection before changing the declaration")
    actual = {
        entry["NSPrivacyAccessedAPIType"]: entry["NSPrivacyAccessedAPITypeReasons"]
        for entry in value.get("NSPrivacyAccessedAPITypes", [])
    }
    check(actual == required, f"Unexpected required-reason declaration: {actual}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="Optional saved .xcarchive to inspect")
    args = parser.parse_args()
    app_source = ROOT / "钱多多"
    required = {"NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"]}
    manifest(app_source / "PrivacyInfo.xcprivacy", required)
    manifest(ROOT / "CommentReminderWidget/PrivacyInfo.xcprivacy", {})
    info = plist(app_source / "Info.plist")
    for key in ["NSMicrophoneUsageDescription", "NSPhotoLibraryAddUsageDescription"]:
        check(bool(info.get(key)), f"Missing permission purpose: {key}")
    check(info.get("ITSAppUsesNonExemptEncryption") is False, "Review the export-compliance declaration")
    check(plist(ROOT / "CommentReminderWidget/Info.plist").get("ITSAppUsesNonExemptEncryption") is False,
          "Missing extension export-compliance declaration")
    check((app_source / "PrivacyPolicy.txt").stat().st_size > 500, "Privacy policy is missing or incomplete")
    check(not list(app_source.rglob("*.m4a")), "Unexpected bundled voice recording")

    audio = app_source / "PublishCelebrationDefault.wav"
    credits = (app_source / "PublishCelebrationDefault.LICENSE.txt").read_text()
    digest = hashlib.sha256(audio.read_bytes()).hexdigest()
    check(digest in credits and "CC0" in credits, "Default audio provenance does not match the asset")
    scheme = ElementTree.parse(ROOT / "钱多多.xcodeproj/xcshareddata/xcschemes/钱多多.xcscheme")
    check(scheme.find("ArchiveAction").get("buildConfiguration") == "Release", "Archive must use Release")
    export = plist(ROOT / "AppStore/ExportOptions.plist")
    check(export.get("method") == "app-store-connect" and export.get("destination") == "export",
          "Export settings must prepare a local App Store export")

    icon_directory = app_source / "Assets.xcassets/AppIcon.appiconset"
    contents = json.loads((icon_directory / "Contents.json").read_text())
    for icon in contents["images"]:
        path = icon_directory / icon["filename"]
        data = path.read_bytes()
        check(data[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid PNG: {path.name}")
        width, height, depth, color_type = struct.unpack(">IIBB", data[16:26])
        scale = float(icon["scale"].removesuffix("x"))
        expected = tuple(round(float(size) * scale) for size in icon["size"].split("x"))
        check((width, height) == expected, f"Incorrect icon size: {path.name}")
        check(depth == 8 and color_type == 2, f"Icon must use opaque RGB encoding: {path.name}")

    project = (ROOT / "钱多多.xcodeproj/project.pbxproj").read_text()
    versions = sorted(set(re.findall(r"MARKETING_VERSION = ([^;]+);", project)))
    builds = sorted(set(re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", project)))
    check(len(versions) == len(builds) == 1, "App, extension and test versions must stay consistent")
    result = {
        "source_checks": "passed",
        "version": versions[0],
        "build": builds[0],
        "default_audio_sha256": digest,
        "app_store_ready": False,
        "remaining": [
            "Confirm Developer Program and App Store Connect app record",
            "Obtain distribution signing and export/validate through Xcode",
            "Verify production CloudKit schema and real-device behavior",
            "Confirm the public privacy-policy URL, fill metadata and provide real screenshots",
        ],
    }
    if args.archive:
        applications = list((args.archive / "Products/Applications").glob("*.app"))
        check(len(applications) == 1, "Expected exactly one app in the archive")
        app = applications[0]
        widget = app / "PlugIns/CommentReminderWidget.appex"
        manifest(app / "PrivacyInfo.xcprivacy", required)
        manifest(widget / "PrivacyInfo.xcprivacy", {})
        for resource in ["PrivacyPolicy.txt", "PublishCelebrationDefault.wav", "PublishCelebrationDefault.LICENSE.txt"]:
            check((app / resource).read_bytes() == (app_source / resource).read_bytes(), f"Stale archive resource: {resource}")
        archived_info = plist(app / "Info.plist")
        widget_info = plist(widget / "Info.plist")
        check(archived_info.get("ITSAppUsesNonExemptEncryption") is False, "Archive lost export declaration")
        check(archived_info["CFBundleShortVersionString"] == widget_info["CFBundleShortVersionString"], "Extension version mismatch")
        check(archived_info["CFBundleVersion"] == widget_info["CFBundleVersion"], "Extension build mismatch")
        check(not list(app.rglob("*.m4a")), "Archive contains an unexpected voice recording")
        signature = subprocess.run(["codesign", "-dv", str(app)], capture_output=True, text=True)
        result["archive_checks"] = "passed"
        result["archive_signed"] = signature.returncode == 0
        result["embedded_profile"] = (app / "embedded.mobileprovision").exists()
        result["note"] = "A valid archive resource check or development signature does not establish App Store distribution readiness."
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
