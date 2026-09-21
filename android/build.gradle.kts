group = "com.enver.lightweight_barcode_scanner"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "com.enver.lightweight_barcode_scanner"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
        externalNativeBuild {
            cmake {
                // C++20 is what the vendored ZXing-C++ 3.x core requires.
                cppFlags += listOf("-std=c++20", "-fexceptions", "-frtti")
                // Static libc++: this is the only library in the plugin that
                // needs it and no C++ object crosses a .so boundary, so
                // linking it in avoids shipping the 1.2 MB libc++_shared.so.
                arguments += listOf("-DANDROID_STL=c++_static")
            }
        }
        consumerProguardFiles("proguard-rules.pro")
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packaging {
        jniLibs {
            // The NDK produces a separate .so per ABI; Flutter's build already
            // splits per ABI, so nothing here needs to be excluded.
            useLegacyPackaging = false
        }
    }

    buildTypes {
        release {
            ndk {
                debugSymbolLevel = "NONE"
            }
        }
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // CameraX handles lifecycle, device quirks, orientation and the analysis
    // pipeline. It never sees the decoder: it only hands us a luminance plane.
    val cameraxVersion = "1.4.2"
    implementation("androidx.camera:camera-core:$cameraxVersion")
    implementation("androidx.camera:camera-camera2:$cameraxVersion")
    implementation("androidx.camera:camera-lifecycle:$cameraxVersion")

    testImplementation("org.jetbrains.kotlin:kotlin-test")
}
