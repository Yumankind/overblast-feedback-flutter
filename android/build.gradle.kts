// The Android half of overblast_feedback: the Android Keystore behind the overblast_feedback/device
// channel. No dependencies beyond the platform; key attestation is in the framework since API 24.
group = "app.overblast.feedback.flutter"
version = "0.2.0"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

// AGP 9 compiles Kotlin itself unless the app opts out with android.builtInKotlin=false; AGP 8 (what
// overblast_app and flutter_app use today) needs the Kotlin plugin applied. Both work, as in
// sensors_plus.
val agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()
val builtInKotlinEnabled =
    agpMajor >= 9 && (providers.gradleProperty("android.builtInKotlin").orNull?.toBoolean() ?: true)
if (!builtInKotlinEnabled) {
    apply(plugin = "org.jetbrains.kotlin.android")
}

project.extensions.configure(org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension::class.java) {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

android {
    namespace = "app.overblast.feedback.flutter"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        // setAttestationChallenge needs API 24, which is also Flutter's own floor.
        minSdk = 24
    }
}
