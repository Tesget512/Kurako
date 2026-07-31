import java.util.Properties

val signingProperties = Properties()
val signingPropertiesFile = rootProject.file("key.properties")
if (signingPropertiesFile.exists()) {
    signingPropertiesFile.inputStream().use(signingProperties::load)
}
val hasOfficialSigning = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .all { !signingProperties.getProperty(it).isNullOrBlank() }

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.tesget.kurako"
    // Force compileSdk 36 to satisfy flutter_plugin_android_lifecycle (file_picker
    // transitive dep was compiled against 34, causing AAR metadata check failure).
    compileSdk = 36
    // All Flutter plugins (media_kit, rust_lib, file_picker, …) require this NDK.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.tesget.kurako"
        // media_kit / libmpv require Android 5.0 (API 21) or newer.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["appLabel"] = "Kurako"
    }

    signingConfigs {
        if (hasOfficialSigning) {
            create("officialRelease") {
                storeFile = file(signingProperties.getProperty("storeFile"))
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        getByName("debug") {
            // Builds made by contributors can coexist with the official app;
            // their debug key can never replace the official Release APK.
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            manifestPlaceholders["appLabel"] = "Kurako Dev"
        }
        getByName("profile") {
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            manifestPlaceholders["appLabel"] = "Kurako Dev"
        }
        release {
            if (hasOfficialSigning) {
                signingConfig = signingConfigs.getByName("officialRelease")
            } else {
                // A source checkout without the private key must not create a
                // misleading APK with the official package id. It remains a
                // separately installable development build instead.
                signingConfig = signingConfigs.getByName("debug")
                applicationIdSuffix = ".dev"
                versionNameSuffix = "-dev"
                manifestPlaceholders["appLabel"] = "Kurako Dev"
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
