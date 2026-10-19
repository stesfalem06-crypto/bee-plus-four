import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing inputs (see the signingConfigs comment below and docs/app_updates.md).
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun sign(env: String, prop: String): String? = System.getenv(env)?.takeIf { it.isNotEmpty() } ?: keyProps.getProperty(prop)
val storePath = sign("FOUR_KEYSTORE", "storeFile")

android {
    namespace = "com.warsay.high"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.four.student"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        jniLibs {
            // Text-recognition native lib is ~11 MB per ABI. Real phones are ARM; on x86_64
            // (emulators / some Chromebooks) the scanner skips text reading and still reads QR.
            excludes += "lib/x86_64/libmlkit_google_ocr_pipeline.so"
        }
    }

    // JVM unit tests (FourChunkReaderTest) call into android.jar stubs only for Uri
    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    // Stable release signing (needed for in-app updates: Android only updates an app signed with the SAME key,
    // and that is what keeps unlock + resources). Provide either env vars (CI) or android/key.properties (local):
    //   FOUR_KEYSTORE=/path/four-release.jks FOUR_KEYSTORE_PASSWORD=… FOUR_KEY_ALIAS=four FOUR_KEY_PASSWORD=…
    // Without them the build falls back to the debug key (fine for testing, NOT for releases: see docs/app_updates.md).
    signingConfigs {
        if (storePath != null && file(storePath).exists()) {
            create("release") {
                storeFile = file(storePath)
                storePassword = sign("FOUR_KEYSTORE_PASSWORD", "storePassword")
                keyAlias = sign("FOUR_KEY_ALIAS", "keyAlias")
                keyPassword = sign("FOUR_KEY_PASSWORD", "keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            // 1.0.3 hardening: never debuggable; R8 shrinks + renames the Kotlin classes (Flutter default, made explicit).
            // Dart code: build with --obfuscate --split-debug-info=<dir> (see docs/app_updates.md).
            isDebuggable = false
            isMinifyEnabled = true
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
    // Bundled (offline) ML Kit models — no Google Play Services download needed.
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
    implementation("com.google.mlkit:text-recognition:16.0.1")
    // In-app live camera for the unlock scanner.
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.camera:camera-view:1.4.2")
    implementation("androidx.exifinterface:exifinterface:1.3.7")
    // Second QR decoder for still photos.
    implementation("com.google.zxing:core:3.5.3")
    // Encrypted add-on videos: ExoPlayer core only (no UI / DASH / HLS modules) fed by FourDataSource.
    implementation("androidx.media3:media3-exoplayer:1.11.1")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.mockito:mockito-core:5.14.2")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.mockito:mockito-core:5.14.2")
}
