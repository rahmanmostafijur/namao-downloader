plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.devtools.ksp")
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
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    composeOptions {
        // Matches Kotlin 1.9.24 per the Compose Compiler <-> Kotlin
        // compatibility map — must move in lockstep with the Kotlin version.
        kotlinCompilerExtensionVersion = "1.5.14"
    }

    packaging {
        // yt-dlp bundles a Python 3.8 runtime; the two native libraries
        // occasionally ship duplicate license/metadata files under the
        // same path, which would otherwise fail the build.
        resources.excludes += setOf("META-INF/LICENSE*", "META-INF/NOTICE*")
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.4")
    implementation("androidx.lifecycle:lifecycle-service:2.8.4")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.4")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.4")

    // Compose UI
    implementation(platform("androidx.compose:compose-bom:2024.06.00"))
    implementation("androidx.activity:activity-compose:1.9.0")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.navigation:navigation-compose:2.7.7")
    debugImplementation("androidx.compose.ui:ui-tooling")

    // Storage Access Framework folder picker (ActivityResultContracts.OpenDocumentTree)
    // and writing into the user-chosen tree Uri via DocumentFile.
    // Pinned to 1.9.0: newer releases (1.10+) pull in transitive deps that
    // require AGP 8.9.1+, but this project is on AGP 8.5.2.
    implementation("androidx.activity:activity-ktx:1.9.0")
    implementation("androidx.documentfile:documentfile:1.1.0")

    // Persistence: download queue + history survive process death and
    // Activity recreation independently of the UI.
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")

    // Settings (theme, Wi-Fi-only, concurrent download limit, defaults).
    implementation("androidx.datastore:datastore-preferences:1.1.1")

    // Thumbnail loading/caching for the analyze and history screens.
    implementation("io.coil-kt:coil-compose:2.6.0")

    // Bundles a real yt-dlp + Python 3.8 runtime and a static ffmpeg build,
    // compiled for Android — this is what lets the app work with no PC and
    // no network dependency on a server we control. See README for the
    // verified Maven Central coordinates (this group id is real despite
    // looking like a personal namespace — it's how the maintainer publishes).
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
}
