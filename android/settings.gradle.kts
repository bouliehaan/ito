rootProject.name = "ito"

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

// The wire: Noise handshake, pairing, framing, protocol, group routing.
// Plain Kotlin/JVM so it is tested on the host and shared with :fakephone.
include(":link")

// The phone bridge itself.
include(":app")

// A JVM stand-in for the phone that speaks the real protocol with synthetic
// data. Lets the Mac app be built and checked without the V60 plugged in.
include(":fakephone")
