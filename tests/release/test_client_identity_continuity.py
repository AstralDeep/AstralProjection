"""Static release-identity continuity guards for extracted native clients."""

from __future__ import annotations

import plistlib
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
    assert "val currentVersionCode = 6" in gradle
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

    assert project.count("CURRENT_PROJECT_VERSION = 61;") == 10
    assert project.count("MARKETING_VERSION = 1.5;") == 10
    assert "CURRENT_PROJECT_VERSION = 1;" not in project
    assert "CURRENT_PROJECT_VERSION = 2;" not in project
    assert "MARKETING_VERSION = 1.4;" not in project
    assert app["CFBundleVersion"] == "$(CURRENT_PROJECT_VERSION)"
    assert watch["CFBundleVersion"] == "$(CURRENT_PROJECT_VERSION)"
