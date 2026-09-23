allprojects {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://androidsdk.insta360.com/repository/maven-public/")
            credentials {
                username = "insta360guest"
                password = "EXMSjSo8OeOrjU7d"
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
