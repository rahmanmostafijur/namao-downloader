import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: android/key.properties (git-ignored) or NAMAO_* environment variables.
// With neither present the release build is signed with the DEBUG key (fine for local
// verification, not for distribution) and a warning is printed.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

fun signingValue(propertyName: String, envName: String): String? =
    keyProperties.getProperty(propertyName) ?: System.getenv(envName)

val releaseStoreFile = signingValue("storeFile", "NAMAO_KEYSTORE_PATH")
val hasReleaseSigning = releaseStoreFile != null

android {
    namespace = "com.namao.flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.namao.flutter"
        // API 29 = Android 10: scoped storage. MediaStore.Downloads lets the app write to
        // Download/Namao with no storage permission, so the app never needs the legacy
        // WRITE_EXTERNAL_STORAGE permission.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // The Flutter Gradle plugin has already set abiFilters to its default platforms by now, and
        // it does not narrow them for --target-platform (the engine's libraries for every ABI would
        // stay in the APK). So, with --target-platform (used by the release workflow: arm64 only,
        // ~62 MB) replace the filter with exactly those ABIs. A universal build leaves out 32-bit x86
        // (those phones are gone; x86_64 is the emulator). Per-ABI builds (--split-per-abi) pick
        // their own ABI, and Gradle refuses a filter alongside splits.
        if (!project.hasProperty("split-per-abi")) {
            val flutterToAbi = mapOf(
                "android-arm" to "armeabi-v7a",
                "android-arm64" to "arm64-v8a",
                "android-x64" to "x86_64",
            )
            val requested = (project.findProperty("target-platform") as String?)
                ?.split(",")
                ?.mapNotNull { flutterToAbi[it.trim()] }
                .orEmpty()
            ndk {
                abiFilters.clear()
                abiFilters += requested.ifEmpty { listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
            }
        }
    }

    packaging {
        jniLibs {
            // youtubedl-android runs yt-dlp's Python and FFmpeg as separate processes straight
            // from the app's native-library directory, so the libraries must be real files.
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = signingValue("storePassword", "NAMAO_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "NAMAO_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "NAMAO_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Keep rules for the engine library (see the file for why).
            proguardFiles("proguard-rules.pro")
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("namao: no release keystore configured; signing the release build with the DEBUG key")
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // On-device engine (GPL-3.0): a Python 3.12 runtime + yt-dlp, QuickJS and FFmpeg builds.
    // See docs/android-engine.md for the licence implications.
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
}
