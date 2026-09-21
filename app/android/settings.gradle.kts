pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // 刻意不用模板默认的 AGP 9.1.0 + Kotlin 2.4.0。依据是 flutter_tts 4.2.5 自己的
    // android/build.gradle：
    //     ext.kotlin_version = '2.2.20'
    //     classpath 'com.android.tools.build:gradle:8.13.0'
    //     apply plugin: 'kotlin-android'        <- 旧式 KGP 应用方式
    // AGP 9 要求所有插件改用 built-in Kotlin，与旧式应用方式冲突，构建必失败
    // （flutter/flutter#192111、#192167）。
    // Kotlin 取 2.2.20 而不取 2.2.21：与 flutter_tts 完全一致可消除版本漂移。
    id("com.android.application") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")
