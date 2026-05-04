plugins {
    `java-library`
    `maven-publish`
}

allprojects {
    group = "software.amazon.smithy.lua"
    version = "0.1.0"
}

subprojects {
    apply(plugin = "java-library")
    apply(plugin = "maven-publish")

    java {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    tasks.withType<JavaCompile> {
        options.encoding = "UTF-8"
    }

    repositories {
        mavenLocal()
        mavenCentral()
    }

    publishing {
        publications {
            create<MavenPublication>("mavenJava") {
                from(components["java"])
            }
        }
    }
}
