import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.hyydra.notes"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.hyydra.pennino"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
        }
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // Leave the release unsigned; the task-graph check below fails the
                // build before an unsigned or debug-signed APK can be published.
                null
            }
        }
    }
}

// Fail loudly instead of publishing an unsigned or debug-signed release APK:
// such an APK cannot be installed over any previous release.
fun isReleaseRequested(): Boolean {
    val requested = gradle.startParameter.taskNames
    if (requested.isNotEmpty()) {
        return requested.any { it.contains("Release") || it.contains("release") }
    }
    // No explicit task names (IDE or tooling API build): fall back to the
    // scheduled task graph.
    return gradle.taskGraph.allTasks.any { it.name.contains("Release") }
}

gradle.taskGraph.whenReady {
    if (isReleaseRequested() && !keystorePropertiesFile.exists()) {
        throw GradleException(
            "android/key.properties is missing, so release builds cannot be signed. " +
                "Refusing to fall back to the debug signing config: a debug-signed " +
                "release APK cannot be installed over previous releases. " +
                "Create android/key.properties (see " +
                "https://docs.flutter.dev/deployment/android#signing-the-app) or " +
                "build a debug variant instead."
        )
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
