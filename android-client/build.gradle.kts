// Root Gradle build for the Android client: declares plugins applied per module in core/ and app/, and locks
// the buildscript and every module's dependency resolution for a reproducible supply chain.

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.compose.compiler) apply false
    alias(libs.plugins.kover) apply false
    alias(libs.plugins.ktlint) apply false
}

buildscript {
    configurations.getByName("classpath") {
        resolutionStrategy.activateDependencyLocking()
    }
}

allprojects {
    dependencyLocking {
        lockAllConfigurations()
    }
}
