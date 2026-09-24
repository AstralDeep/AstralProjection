// Gradle build for :core, the pure-Kotlin module (protocol decode, SDUI model, streaming, REST shaping) kept
// Android-free so it's JVM-unit-testable without an emulator; Kover enforces a module coverage gate here.

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.kover)
    alias(libs.plugins.ktlint)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.core)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.kotlin.test.junit)
}

tasks.test {
    useJUnit()
}

kover {
    reports {
        verify {
            rule {
                minBound(90)
            }
        }
    }
}
