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
