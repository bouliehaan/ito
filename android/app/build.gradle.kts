import java.util.Properties

plugins {
    id("com.android.application")
}

// The release key matters more than usual here: ito is installed as a
// privileged system app through Magisk, and Android only lets a system app be
// updated by an APK with the SAME signature. tools/keystore.sh makes the key
// once (gitignored); losing it means reinstalling the Magisk module.
// One version for the phone and the Mac: /VERSION. The phone's versionCode is derived
// (1.2.3 -> 10203) so it always goes up with the version, or Android refuses the update.
val itoVersion = rootProject.file("../VERSION").readText().trim()
val itoVersionCode = itoVersion.split(".").map(String::toInt).let { (a, b, c) -> a * 10000 + b * 100 + c }

val keystoreProperties =
    rootProject.file("keystore/keystore.properties").takeIf { it.exists() }?.let { f ->
        Properties().apply { f.inputStream().use { load(it) } }
    }

android {
    namespace = "app.ito"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.ito"
        // 33: the call-audio redirection API and Conscrypt's X25519 are both there.
        minSdk = 33
        targetSdk = 36
        versionCode = itoVersionCode
        versionName = itoVersion
    }

    signingConfigs {
        create("release") {
            if (keystoreProperties != null) {
                storeFile = rootProject.file("keystore/" + keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            if (keystoreProperties != null) signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    lint {
        // SMS/call permissions are the point of this app and it is never on Play.
        disable += setOf("ProtectedPermissions", "ExpiredTargetSdkVersion")
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(project(":link"))
}
