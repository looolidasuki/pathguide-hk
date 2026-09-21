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
    // 刻意不用模板默认的 AGP 9.1.0。AGP 9 要求所有插件改用 built-in Kotlin，
    // 而 flutter_tts 仍按旧方式应用 Kotlin Gradle Plugin，构建会失败
    // （flutter/flutter#192111、#192167）。
    // 取 AGP 8.x 的最后一个稳定版 8.13.2（已查 Google Maven 确认存在），
    // 最可能与 Flutter 3.47 配合；Gradle 相应停在 8.13。
    id("com.android.application") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

include(":app")
