// Gradle settings: module includes for the Android client plus a locked, JitPack-pinned dependency-resolution
// classpath for reproducible, supply-chain-locked builds.

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
buildscript {
    configurations.getByName("classpath") {
        resolutionStrategy.activateDependencyLocking()
    }
}

plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://jitpack.io")
            content {
                // JitPack pin for LiveKit's AudioSwitch — never widen this repo's scope
                includeModule("com.github.davidliu", "audioswitch")
            }
        }
    }
}

rootProject.name = "astral-android"
enableFeaturePreview("TYPESAFE_PROJECT_ACCESSORS")
include(":core", ":app")
