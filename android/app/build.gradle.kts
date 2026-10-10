import java.util.Properties

plugins {
    id("com.android.application")
}

// The release key matters more than usual here: ito is installed as a
// privileged system app through Magisk, and Android only lets a system app be
// updated by an APK with the SAME signature. tools/keystore.sh makes the key
// once (gitignored); losing it means reinstalling the Magisk module.
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
        versionCode = 2
        versionName = "0.1.1"
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
