"""Static release-identity continuity guards for extracted native clients."""

from __future__ import annotations

import plistlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def _text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def _plist(relative_path: str) -> dict[str, object]:
    return plistlib.loads((ROOT / relative_path).read_bytes())


def test_android_store_and_oidc_identity_remain_registered_values() -> None:
    gradle = _text("android-client/app/build.gradle.kts")
    manifest = _text("android-client/app/src/main/AndroidManifest.xml")
    app_config = _text(
        "android-client/app/src/main/kotlin/com/personalailabs/astraldeep/app/AppConfig.kt"
    )
    oidc_auth = _text(
        "android-client/app/src/main/kotlin/com/personalailabs/astraldeep/app/auth/OidcAuth.kt"
    )

    assert 'val registeredApplicationId = "com.personalailabs.astraldeep"' in gradle
    assert 'val registeredRedirectScheme = "com.personalailabs.astraldeep"' in gradle
    assert "val migrationVersionCodeFloor = 5" in gradle
    assert "val currentVersionCode = 8" in gradle
    assert "check(currentVersionCode >= migrationVersionCodeFloor)" in gradle
    assert "applicationId = registeredApplicationId" in gradle
    assert "versionCode = currentVersionCode" in gradle
    assert 'versionName = "1.4"' in gradle
    assert 'manifestPlaceholders["appAuthRedirectScheme"] = registeredRedirectScheme' in gradle

    redirect_uri = "com.personalailabs.astraldeep:/oauth2redirect"
    assert f'const val OIDC_REDIRECT_URI: String = "{redirect_uri}"' in app_config
    assert "Uri.parse(AppConfig.OIDC_REDIRECT_URI)" in oidc_auth
    assert 'android:scheme="${appAuthRedirectScheme}"' in manifest


def test_android_release_signing_stays_private_and_indirect() -> None:
    gradle = _text("android-client/app/build.gradle.kts")
    runbook = _text("android-client/docs/play-store-release.md")

    assert 'rootProject.file("keystore.properties")' in gradle
    assert 'create("release")' in gradle
    assert 'storeFile = file(keystoreProperties.getProperty("storeFile"))' in gradle
    assert 'storePassword = keystoreProperties.getProperty("storePassword")' in gradle
    assert 'keyAlias = keystoreProperties.getProperty("keyAlias")' in gradle
    assert 'keyPassword = keystoreProperties.getProperty("keyPassword")' in gradle
    assert 'signingConfig = signingConfigs.findByName("release")' in gradle
    assert "astral-upload" not in gradle
    assert "Upload key\ncertificate SHA-256 fingerprint" in runbook
    assert "Compare the printed SHA256 fingerprint exactly with Play Console" in runbook
    assert "Owner should read:" not in runbook


def test_apple_release_project_pins_distribution_identity_and_profile_mapping() -> None:
    project = _text("apple-clients/AstralApp/AstralApp.xcodeproj/project.pbxproj")
    base_config = _text("apple-clients/Config/Base.xcconfig")

    assert '"CODE_SIGN_IDENTITY[sdk=iphoneos*]" = "Apple Distribution";' in project
    assert '"CODE_SIGN_IDENTITY[sdk=macosx*]" = "Apple Distribution";' in project
    assert '"CODE_SIGN_IDENTITY[sdk=watchos*]" = "Apple Distribution";' in project
    assert '"PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]" = "$(ASTRAL_PROFILE_IOS)";' in project
    assert '"PROVISIONING_PROFILE_SPECIFIER[sdk=macosx*]" = "$(ASTRAL_PROFILE_MACOS)";' in project
    assert '"PROVISIONING_PROFILE_SPECIFIER[sdk=watchos*]" = "$(ASTRAL_PROFILE_WATCH)";' in project
    assert "PRODUCT_BUNDLE_IDENTIFIER = com.personalailabs.astraldeep;" in project
    assert "PRODUCT_BUNDLE_IDENTIFIER = com.personalailabs.astraldeep.watch;" in project

    assert "DEVELOPMENT_TEAM = $(ASTRAL_DEVELOPMENT_TEAM)" in base_config
    assert "ASTRAL_PROFILE_IOS =" in base_config
    assert "ASTRAL_PROFILE_MACOS =" in base_config
    assert "ASTRAL_PROFILE_WATCH =" in base_config


def test_apple_export_options_preserve_manual_store_signing() -> None:
    ios = _plist("apple-clients/ExportOptions-ios.plist")
    macos = _plist("apple-clients/ExportOptions-macos.plist")

    assert ios["method"] == "app-store-connect"
    assert ios["signingStyle"] == "manual"
    assert ios["manageAppVersionAndBuildNumber"] is False
    assert ios["provisioningProfiles"] == {
        "com.personalailabs.astraldeep": "${APPLE_PROFILE_IOS}",
        "com.personalailabs.astraldeep.watch": "${APPLE_PROFILE_WATCH}",
    }

    assert macos["method"] == "app-store-connect"
    assert macos["signingStyle"] == "manual"
    assert macos["manageAppVersionAndBuildNumber"] is False
    assert macos["installerSigningCertificate"] == "3rd Party Mac Developer Installer"
    assert macos["provisioningProfiles"] == {
        "com.personalailabs.astraldeep": "${APPLE_PROFILE_MACOS}",
    }


def test_apple_bundles_take_the_protected_monotonic_build_number() -> None:
    project = _text("apple-clients/AstralApp/AstralApp.xcodeproj/project.pbxproj")
    app = _plist("apple-clients/AstralApp/Info.plist")
    watch = _plist("apple-clients/AstralApp/WatchInfo.plist")

    configurations = _project_objects(project, "XCBuildConfiguration")
    original = {
        "222F50332FFD60D90016B0D6", "222F50342FFD60D90016B0D6",
        "AA00000000000000000000B8", "AA00000000000000000000B9",
        "AA00000000000000000000E9", "AA00000000000000000000EA",
        "AB0000000000000000000011", "AB0000000000000000000012",
        "AB0000000000000000000014", "AB0000000000000000000015",
    }
    navigation = {
        "AD0881000000000000000014", "AD0881000000000000000015",
        "AD0881000000000000000016", "AD0881000000000000000017",
    }
    versioned = {key for key, body in configurations.items() if "CURRENT_PROJECT_VERSION" in body}
    assert versioned == original | navigation
    assert len(original) == 10 and len(navigation) == 4
    for key in original | navigation:
        assert "CURRENT_PROJECT_VERSION = 62;" in configurations[key]
        assert "MARKETING_VERSION = 1.6;" in configurations[key]
    for key in navigation:
        body = configurations[key]
        assert "SUPPORTED_PLATFORMS = watchsimulator;" in body
        assert "SKIP_INSTALL = YES;" in body
        assert "CODE_SIGNING_ALLOWED = NO;" in body
        assert "PRODUCT_NAME = AstralWatchNavigation" in body
    assert "CURRENT_PROJECT_VERSION = 1;" not in project
    assert "CURRENT_PROJECT_VERSION = 2;" not in project
    assert "MARKETING_VERSION = 1.4;" not in project
    assert app["CFBundleVersion"] == "$(CURRENT_PROJECT_VERSION)"
    assert watch["CFBundleVersion"] == "$(CURRENT_PROJECT_VERSION)"


def _project_objects(project: str, section: str) -> dict[str, str]:
    text = project.split(f"/* Begin {section} section */", 1)[1].split(f"/* End {section} section */", 1)[0]
    return dict(re.findall(r"^\t\t([A-F0-9]{24}) /\* .*? \*/ = \{\n(.*?)^\t\t\};", text, re.M | re.S))


def test_watch_navigation_harness_stays_outside_shipping_targets_and_archives() -> None:
    project = _text("apple-clients/AstralApp/AstralApp.xcodeproj/project.pbxproj")
    targets = _project_objects(project, "PBXNativeTarget")
    harness, ui = "AD0881000000000000000008", "AD0881000000000000000009"
    assert "name = AstralWatchNavigationHarness;" in targets[harness]
    assert "name = AstralWatchNavigationUITests;" in targets[ui]
    assert 'productType = "com.apple.product-type.bundle.ui-testing";' in targets[ui]
    app, watch = targets["222F50262FFD60D80016B0D6"], targets["AA00000000000000000000B3"]
    assert re.search(r"dependencies = \(\s*AA00000000000000000000C3 /\* PBXTargetDependency \*/,\s*\);", app)
    assert re.search(r"dependencies = \(\s*\);", watch)
    for body in (app, watch):
        assert "AD0881" not in body
    schemes = ROOT / "apple-clients/AstralApp/AstralApp.xcodeproj/xcshareddata/xcschemes"
    for name in ("AstralApp", "AstralWatch"):
        tree = ET.parse(schemes / f"{name}.xcscheme")
        assert all(node.get("BlueprintIdentifier") not in {harness, ui}
                   for node in tree.findall(".//BuildableReference"))
    tree = ET.parse(schemes / "AstralWatchNavigation.xcscheme")
    assert tree.find("ArchiveAction") is None
    entries = tree.findall(".//BuildActionEntry")
    assert entries and all(node.get("buildForArchiving") == "NO" for node in entries)
    references = tree.findall(".//BuildableReference")
    assert {node.get("BlueprintIdentifier") for node in references} == {harness, ui}
    assert "membershipExceptions = (AstralWatchApp.swift, );" in project
