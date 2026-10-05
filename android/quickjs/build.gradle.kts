plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.psyche.kelivo.quickjs"
    compileSdk = 35

    defaultConfig {
        minSdk = 24

        // In skeleton (CI) builds we deliberately skip compiling QuickJS so
        // the resulting APK lacks the native .so and is only usable as a
        // structural artifact. Set -PkiteSkeletonBuild=true to enable.
        if (project.findProperty("kiteSkeletonBuild") != "true") {
            externalNativeBuild {
                cmake {
                    cppFlags("-std=c++17")
                }
            }
        }

        ndk {
            abiFilters.addAll(listOf("arm64-v8a"))
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
        debug {
            isMinifyEnabled = false
        }
    }

    if (project.findProperty("kiteSkeletonBuild") != "true") {
        externalNativeBuild {
            cmake {
                path = file("src/main/cpp/CMakeLists.txt")
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
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")
}
