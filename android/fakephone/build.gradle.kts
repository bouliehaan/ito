plugins {
    id("org.jetbrains.kotlin.jvm")
    application
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(project(":link"))
    implementation("org.json:json:20240303")
}

application {
    mainClass.set("app.ito.fakephone.MainKt")
}

tasks.named<JavaExec>("run") {
    standardInput = System.`in`
}
