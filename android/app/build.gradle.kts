/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Parts of this file are derived from SDL 2's Android project template, which
 * has a different license. Please see vendor/SDL/LICENSE.txt for details.
 */
import java.util.Properties
import org.gradle.nativeplatform.platform.internal.DefaultNativePlatform

plugins {
    id("com.android.application") version("8.10.1")
    id("com.github.willir.rust.cargo-ndk-android") version("0.3.4")
    id("org.jetbrains.kotlin.android") version("2.0.21")
}

fun runTouchHLEVersionTool(wantBranding: Boolean): String {
    val output = providers.exec {
        commandLine("cargo", "run", "--package", "touchHLE_version")
        if (wantBranding) {
            args("--", "--branding")
        }
    }.standardOutput.asText.get().trim()

    return output
}

fun getTouchHLEBranding(): String {
    return runTouchHLEVersionTool(/* wantBranding: */ true)
}

// The app's version and build number are set only in iphone/Config.xcconfig,
// for iOS and Android alike (see the comment there).
fun getXcconfigSetting(key: String): String {
    val xcconfig = rootDir.parentFile.resolve("iphone/Config.xcconfig")
    return xcconfig.readLines().firstNotNullOfOrNull { line ->
        val parts = line.split("=", limit = 2)
        if (parts.size == 2 && parts[0].trim() == key) parts[1].trim() else null
    } ?: throw GradleException("$key must be set in iphone/Config.xcconfig")
}

fun getVersionName(): String {
    return getXcconfigSetting("MARKETING_VERSION")
}

// The versionCode is made from the version and build number: 1.2.23 build 1
// is 1022301.
fun getVersionCode(): Int {
    val version = getVersionName().split(".").map { it.toInt() }
    val build = getXcconfigSetting("CURRENT_PROJECT_VERSION").toInt()
    if (version.size != 3 || version[1] > 99 || version[2] > 99 || build !in 1..99) {
        throw GradleException("Can't make a versionCode from ${getVersionName()} build $build")
    }
    return version[0] * 1000000 + version[1] * 10000 + version[2] * 100 + build
}

// Release builds are signed with the key in android/keystore.properties, which
// is git-ignored, if there is one, and otherwise with the debug key.
val keystorePropertiesFile = rootProject.file("keystore.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

fun join(prefix: String, separator: String, branding: String): String {
    return if (branding.isEmpty()) prefix else prefix + separator + branding
}

android {
    // NDK r28 and later build native code for 16 KB memory pages by default.
    ndkVersion = "28.2.13676358"
    compileSdk = 36
    buildFeatures {
        buildConfig = true
    }
    defaultConfig {
        val branding = getTouchHLEBranding()
        applicationId = "org.alexmartin.idared32bit"
        if (!branding.isEmpty()) {
            applicationIdSuffix = branding.lowercase()
        }
        resValue("string", "app_name", join("iDared 32bit", " ", branding))
        buildConfigField("String", "APP_NAME", "\"${join("iDared 32bit", " ", branding)}\"")
        manifestPlaceholders["icon"] = join("@drawable/icon", "_", branding.lowercase())
        buildConfigField("int", "APP_ICON", join("R.drawable.icon", "_", branding.lowercase()))
        versionName = join(getVersionName(), " ", branding)
        versionCode = getVersionCode()

        minSdk = 21 // first version with AArch64
        targetSdk = 36
        externalNativeBuild {
            ndkBuild {
                arguments("APP_PLATFORM=android-21")
                // abiFilters 'armeabi-v7a', 'arm64-v8a', 'x86', 'x86_64'
                // touchHLE's CPU emulation backend is now an interpreter
                // derived from mGBA's, in portable C with no host-architecture-
                // specific code generation, so unlike with the Dynarmic-based
                // backend, all four ABIs above should work in principle. The
                // 'x86_64' build works, but the main use for that would be
                // the emulator in Android Studio, and its OpenGL ES
                // implementations don't seem to work properly with touchHLE,
                // so we disable it to reduce build time and avoid shipping
                // stuff we haven't meaningfully tested. The others remain
                // untested for now too.
                // Make sure this matches the cargoNdk targets below.
                abiFilters("arm64-v8a")
            }
        }
    }
    // The target JVM version must be the same for Java and Kotlin.
    compileOptions {
        sourceCompatibility(JavaVersion.VERSION_11)
        targetCompatibility(JavaVersion.VERSION_11)
    }
    kotlinOptions {
        jvmTarget = "11"
    }
    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("upload") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("upload")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            // Files can be managed with the Files app, through
            // DocumentsProvider.
            isDebuggable = false
        }
        debug {
            isMinifyEnabled = false
            packaging {
                jniLibs.keepDebugSymbols.add("**/*.so")
            }
            isDebuggable = true
            isJniDebuggable = true
        }
    }

    applicationVariants.all {
        val variantName = name.replaceFirstChar { char ->
            if (char.isLowerCase()) char.titlecase() else char.toString()
        }
        tasks.named("merge${variantName}Assets").configure {
            dependsOn("externalNativeBuild${variantName}")
        }
    }

    sourceSets {
        getByName("main") {
            java.srcDir("${rootDir.parentFile}/vendor/SDL/android-project/app/src/main/java")
        }
    }

    if (!project.hasProperty("EXCLUDE_NATIVE_LIBS")) {
        sourceSets {
            getByName("main") {
                jniLibs.srcDir("${projectDir}/jniLibs")
            }
        }
        externalNativeBuild {
            ndkBuild {
                path("jni/Android.mk")
            }
        }
    }

    lint {
        abortOnError = false
    }
    namespace = "org.alexmartin.idared32bit"
}

cargoNdk {
    // Make sure this matches the android abiFilters above.
    targets = arrayListOf("arm64")
    module = ".."
    librariesNames = arrayListOf("libtouchHLE.so", "libSDL2.so", "libc++_shared.so")
    extraCargoEnv = mapOf(
        "ANDROID_NDK" to android.ndkDirectory.toString(),
        "ANDROID_NDK_HOME" to android.ndkDirectory.toString(),
    )

    if (DefaultNativePlatform.host().operatingSystem.isWindows) {
        val binPath =
            android.ndkDirectory.toPath().resolve("toolchains/llvm/prebuilt/windows-x86_64/bin")
        val clangPath = binPath.resolve("clang.exe")
        val clangXXPath = binPath.resolve("clang++.exe")

        if (!clangPath.toFile().exists()) {
            throw GradleException("NDK clang compiler not found at expected location: $clangPath")
        }
        if (!clangXXPath.toFile().exists()) {
            throw GradleException("NDK clang++ compiler not found at expected location: $clangXXPath")
        }

        extraCargoEnv.putAll(
            mapOf(
                "CC" to clangPath.toString(),
                "CXX" to clangXXPath.toString(),
                // The default generator on Windows (Visual Studio) does not respect
                // the CC and CXX environment variables. Using Ninja ensures that
                // the specified compilers are used
                "CMAKE_GENERATOR" to "Ninja",
            )
        )
    }
    // The default feature, "static", makes us use static linking for SDL2 and OpenAL Soft.
    // For Android, we need dynamic linking for SDL2, but static linking for OpenAL Soft.
    extraCargoBuildArguments = arrayListOf(
        "--lib",
        "--no-default-features",
        "--features",
        "sdl2/bundled"
    )
}

dependencies {
    implementation(fileTree("libs") {
        include("*.jar")
    })
}
