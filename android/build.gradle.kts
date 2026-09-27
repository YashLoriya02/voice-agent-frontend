import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinJvmCompilerOptions
import org.jetbrains.kotlin.gradle.tasks.KotlinCompilationTask


allprojects {
    repositories {
        google()
        mavenCentral()
    }
}


val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()

rootProject.layout.buildDirectory.value(
    newBuildDir
)


subprojects {
    val newSubprojectBuildDir: Directory =
        newBuildDir.dir(project.name)

    project.layout.buildDirectory.value(
        newSubprojectBuildDir
    )
}


subprojects {
    project.evaluationDependsOn(":app")
}


/*
 * Fix JVM target mismatch for all Kotlin
 * Android modules/plugins.
 *
 * audio_stream_player:
 *
 * Java   = 17
 * Kotlin = was becoming 21
 *
 * Force Kotlin to 17.
 */
subprojects {

    tasks.withType<
        KotlinCompilationTask<
            KotlinJvmCompilerOptions
        >
    >().configureEach {

        compilerOptions {
            jvmTarget.set(
                JvmTarget.JVM_17
            )
        }
    }
}


tasks.register<Delete>("clean") {
    delete(
        rootProject.layout.buildDirectory
    )
}