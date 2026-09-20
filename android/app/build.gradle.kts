plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.namao.app"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.namao.app"
        // 26+ lets the adaptive launcher icon be the only icon resource
        // needed (no raster mipmap fallbacks) and covers the vast majority
        // of active devices as of 2026.
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"

        ndk {
            // youtubedl-android and ffmpeg ship a full Python + ffmpeg build
            // per ABI, so a universal APK quadruples in size for nothing —
            // arm64-v8a alone covers virtually every Android phone sold
            // since ~2017. Add "armeabi-v7a" back only if a target device
            // turns out to be 32-bit-only (very old/rare at this point).
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    packaging {
        // yt-dlp bundles a Python 3.8 runtime; the two native libraries
        // occasionally ship duplicate license/metadata files under the
        // same path, which would otherwise fail the build.
        resources.excludes += setOf("META-INF/LICENSE*", "META-INF/NOTICE*")
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.webkit:webkit:1.11.0")
    // For the Storage Access Framework folder picker (ActivityResultContracts.OpenDocumentTree)
    // and writing into the user-chosen tree Uri via DocumentFile.
    // Pinned to 1.9.0: newer releases (1.10+) pull in transitive deps that
    // require AGP 8.9.1+, but this project is on AGP 8.5.2.
    implementation("androidx.activity:activity-ktx:1.9.0")
    implementation("androidx.documentfile:documentfile:1.1.0")

    // Bundles a real yt-dlp + Python 3.8 runtime and a static ffmpeg build,
    // compiled for Android — this is what lets the app work with no PC and
    // no network dependency on a server we control. See README for the
    // verified Maven Central coordinates (this group id is real despite
    // looking like a personal namespace — it's how the maintainer publishes).
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
}
