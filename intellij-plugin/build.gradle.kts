plugins {
    id("java")
    id("org.jetbrains.kotlin.jvm") version "1.9.21"
    id("org.jetbrains.intellij.platform") version "2.2.1"
}

group = "com.aidashboad"
version = "0.2.19"

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

dependencies {
    intellijPlatform {
        intellijIdeaCommunity("2023.3")
        // Dart plugin from marketplace (optional dependency)
        plugin("Dart", "233.11799.172")
    }
    // Gson for JSON parsing (MCP config management)
    implementation("com.google.code.gson:gson:2.10.1")
    // Note: Kotlin coroutines are provided by IntelliJ Platform, no need to add explicitly
}

intellijPlatform {
    pluginConfiguration {
        name = "Flutter Skill"
        ideaVersion {
            sinceBuild = "233"
            untilBuild = "253.*"
        }
    }

    signing {
        certificateChain = providers.environmentVariable("CERTIFICATE_CHAIN")
        privateKey = providers.environmentVariable("PRIVATE_KEY")
        password = providers.environmentVariable("PRIVATE_KEY_PASSWORD")
    }

    publishing {
        token = providers.environmentVariable("PUBLISH_TOKEN")
    }
}

tasks {
    withType<JavaCompile> {
        sourceCompatibility = "17"
        targetCompatibility = "17"
    }

    withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile> {
        kotlinOptions.jvmTarget = "17"
    }
}
