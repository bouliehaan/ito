plugins {
    id("org.jetbrains.kotlin.jvm")
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    // Android ships org.json in the framework, so the app gets it for free.
    // On the host (tests, :fakephone) it has to come from Maven.
    compileOnly("org.json:json:20240303")
    testImplementation("org.json:json:20240303")
    testImplementation("junit:junit:4.13.2")
}

tasks.test {
    // The Noise vector lives at the repo root so the Swift tests read the same file.
    systemProperty("ito.vectors", rootProject.file("../vectors").absolutePath)
}
