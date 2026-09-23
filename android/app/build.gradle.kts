import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingPropertiesFile = rootProject.file("key.properties")
val signingProperties = Properties()
if (signingPropertiesFile.exists()) {
    signingPropertiesFile.inputStream().use { signingProperties.load(it) }
}

val developerStoreFile = signingProperties.getProperty("storeFile")
val developerStorePassword = signingProperties.getProperty("storePassword")
val developerKeyAlias = signingProperties.getProperty("keyAlias")
val developerKeyPassword = signingProperties.getProperty("keyPassword")
val hasDeveloperSigning = listOf(
    developerStoreFile,
    developerStorePassword,
    developerKeyAlias,
    developerKeyPassword,
).all { !it.isNullOrBlank() }

android {
    namespace = "com.example.dayweather"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.dayweather"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (hasDeveloperSigning) {
        signingConfigs {
            create("developer") {
                storeFile = rootProject.file(requireNotNull(developerStoreFile))
                storePassword = requireNotNull(developerStorePassword)
                keyAlias = requireNotNull(developerKeyAlias)
                keyPassword = requireNotNull(developerKeyPassword)
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasDeveloperSigning) {
                signingConfigs.getByName("developer")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    buildFeatures {
        viewBinding = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        freeCompilerArgs.add("-Xskip-metadata-version-check")
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.arashivision.sdk:sdk-camera:2.1.5")
    implementation("com.arashivision.sdk:sdk-media:2.1.5")
}
