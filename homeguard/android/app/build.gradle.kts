import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Upload-key signing. Locally: android/key.properties (git-ignored).
// In CI: ANDROID_KEYSTORE_PATH / ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS /
// ANDROID_KEY_PASSWORD environment variables.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun signingValue(prop: String, env: String): String? =
    keyProps.getProperty(prop) ?: System.getenv(env)

val releaseStoreFile = signingValue("storeFile", "ANDROID_KEYSTORE_PATH")

// Explicit opt-in for sideloadable tester builds (HOMEGUARD_TEST_BUILD=true):
// separate app id "<id>.test" and debug-key signing. These APKs can never
// be uploaded over the Play app, because the id and signature differ.
val isTestBuild = System.getenv("HOMEGUARD_TEST_BUILD") == "true"

android {
    namespace = "com.homeguard.local.homeguard"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Change before publishing to the Play Store.
        applicationId = "com.homeguard.local.homeguard"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 9+: BiometricPrompt with FlutterFragmentActivity needs no AppCompat
        // launch theme, and Keystore-backed AES-GCM is available everywhere.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["appLabel"] = "HomeGuard"
    }

    signingConfigs {
        create("release") {
            if (releaseStoreFile != null) {
                storeFile = file(releaseStoreFile)
                storePassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Never fall back to the debug key silently: Play rejects debug-signed
            // bundles, and a quietly debug-signed release is a supply-chain risk.
            signingConfig = when {
                isTestBuild -> signingConfigs.getByName("debug")
                releaseStoreFile != null -> signingConfigs.getByName("release")
                else -> null
            }
            if (isTestBuild) {
                applicationIdSuffix = ".test"
                versionNameSuffix = "-test"
                manifestPlaceholders["appLabel"] = "HomeGuard Test"
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
