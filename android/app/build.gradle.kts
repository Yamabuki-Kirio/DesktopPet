plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "asia.akechi.petlife"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 应用标识（Phase 4A 第 2 项要求）
        applicationId = "asia.akechi.petlife"
        // minSdk 跟随 Flutter 模板（3.47 = 24，已高于依赖要求）：
        //   * flutter_secure_storage 等已不再引入；现有依赖要求 API 21+。
        // targetSdk / compileSdk 一律用 flutter.*，与模板保持一致。
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    testOptions {
        // 悬浮窗的纯逻辑（状态机 / 窗口参数 / 几何换算）在 JVM 单测里跑，
        // 它们只用到 Android 的**编译期常量**；万一触达未实现的方法，
        // 这里让它们返回默认值而不是抛 "not mocked"。
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    // Phase 4C：原生悬浮桌宠的单元测试。只用 JUnit4 —— 需要 Context/WindowManager
    // 的部分**不**在这里假装通过，那些必须靠真机仪器测试（见 docs/35）。
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
