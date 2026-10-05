plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.psyche.kelivo.llm.llama"
    compileSdk = 35

    defaultConfig {
        minSdk = 24

        ndk {
            abiFilters.addAll(listOf("arm64-v8a"))
        }

        // In skeleton (CI) builds we deliberately skip compiling llama.cpp so
        // the resulting APK lacks the native .so and is only usable as a
        // structural artifact. Set -PkiteSkeletonBuild=true to enable.
        if (project.findProperty("kiteSkeletonBuild") != "true") {
            externalNativeBuild {
                cmake {
                    cppFlags += listOf("-std=c++17", "-fno-emulated-tls")
                }
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    if (project.findProperty("kiteSkeletonBuild") != "true") {
        externalNativeBuild {
            cmake {
                path = file("CMakeLists.txt")
                version = "3.22.1"
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
}
