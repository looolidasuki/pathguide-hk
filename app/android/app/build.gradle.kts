plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "hk.pathguide.pathguide"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "hk.pathguide.pathguide"
        // CameraX 1.6 需要 API 21+；LiteRT 2.2 需要 API 21+。
        // 直接用 flutter.minSdkVersion，若低于 21 再显式提高。
        minSdk = maxOf(flutter.minSdkVersion, 21)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: 正式发布前换成自己的签名配置。
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    androidResources {
        // 模型不要压缩打包。
        // AssetManager 默认的 open() 走文件描述符，对压缩存储的资源不适用；
        // 虽然代码里已改用 ACCESS_BUFFER 兜底，但保持未压缩能少一层不确定性
        // （也便于用 openFd 做内存映射）。
        noCompress += "tflite"
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // CameraX：预览 + 图像分析共用同一个相机会话。
    // 版本已在 Google Maven 上确认为稳定版（1.6.2）。
    val cameraxVersion = "1.6.2"
    implementation("androidx.camera:camera-core:$cameraxVersion")
    implementation("androidx.camera:camera-camera2:$cameraxVersion")
    implementation("androidx.camera:camera-lifecycle:$cameraxVersion")
    implementation("androidx.camera:camera-view:$cameraxVersion")

    // LiteRT（TensorFlow Lite 的后继）：保留 org.tensorflow.lite.Interpreter 类名，
    // 自带 jni/arm64-v8a/liblitert_jni.so，与目标真机（Redmi Note 11T Pro）架构匹配。
    implementation("com.google.ai.edge.litert:litert:2.2.0")

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
}

flutter {
    source = "../.."
}
