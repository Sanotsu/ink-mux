import java.util.Properties
import java.io.FileInputStream
import org.gradle.api.tasks.Copy

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.swm.ink_mux"
    // flutter_local_notifications 23.x 要求 compileSdk >= 37（AGP 9.3 官方支持 API 37，向后兼容）
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 23.x 要求启用核心库脱糖
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.swm.ink_mux"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
            storePassword = keystoreProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            // 使用 keystore.properties 中的正式签名（该文件不入库，密钥信息只在本地）
            signingConfig = signingConfigs.getByName("release")
        }
    }

    packaging {
        jniLibs {
            // .so 在 APK 内压缩存储，显著减小下载体积（代价：安装后解压占用略增，启动开销可忽略）
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}

// ---- 发行产物重命名 ----
// Flutter 的 APK 输出名固定为 app[-<abi>]-<mode>.apk（Flutter Gradle 插件在
// assembleRelease 内拷到 build/app/outputs/flutter-apk/，无改名参数）。
// 这里在 assembleRelease 结束后把产物再拷一份到项目根 dist/<版本>/，
// 命名与 Windows 绿色版对齐：InkMux-<versionName>+<versionCode>-android-<abi>-release.apk
// 纯 Gradle 实现（Kotlin DSL），Windows / macOS / Linux 行为一致，与构建命令参数无关。
val distDir = rootProject.file("../dist")

val copyFlutterApksToDist = tasks.register<Copy>("copyFlutterApksToDist") {
    from(layout.buildDirectory.dir("outputs/flutter-apk")) {
        // --split-per-abi 产出 3 个 ABI 包；不带该参数时产出 universal 包
        include("app-*-release.apk", "app-release.apk")
        rename { original ->
            val abi = when {
                "arm64-v8a" in original -> "arm64"
                "armeabi-v7a" in original -> "arm"
                "x86_64" in original -> "x64"
                else -> "universal"
            }
            "InkMux-${flutter.versionName}+${flutter.versionCode}-android-$abi-release.apk"
        }
    }
    into(distDir.resolve("${flutter.versionName}+${flutter.versionCode}"))
}

tasks.configureEach {
    if (name == "assembleRelease") {
        finalizedBy(copyFlutterApksToDist)
    }
}
