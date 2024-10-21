plugins {
    `java-library`
    `maven-publish`
}

allprojects {
    group = "software.amazon.smithy.lua"
    version = "0.0.1"
}

repositories {
    mavenLocal()
    mavenCentral()
}

subprojects {
    val subproject = this

    /*
     * Java
     * ====================================================
     */
    if (subproject.name != "smithy-lua-codegen-test") {
        apply(plugin = "java-library")

        java {
            toolchain {
                languageVersion.set(JavaLanguageVersion.of(17))
            }
        }

        tasks.withType<JavaCompile> {
            options.encoding = "UTF-8"
        }

        // Use Junit5's test runner.
        tasks.withType<Test> {
            useJUnitPlatform()
        }

        // Apply junit 5 and hamcrest test dependencies to all java projects.
        dependencies {
            testImplementation("org.junit.jupiter:junit-jupiter-api:5.4.0")
            testImplementation("org.junit.jupiter:junit-jupiter-engine:5.4.0")
            testImplementation("org.junit.jupiter:junit-jupiter-params:5.4.0")
            testImplementation("org.hamcrest:hamcrest:2.1")
        }

        tasks.register<Jar>("sourcesJar") {
            from(sourceSets.main.get().allJava)
            archiveClassifier.set("sources")
        }

        apply(plugin = "maven-publish")

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
}