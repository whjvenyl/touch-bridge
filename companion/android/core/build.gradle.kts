plugins {
    id("com.android.library")
    id("com.google.protobuf")
}

android {
    namespace = "dev.touchbridge.core"
    compileSdk = 37

    defaultConfig {
        minSdk = 26  // Android 8 — lowest we support for BLE + Keystore
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

// Protobuf code generation — generates Java from .proto files at build time.
// Proto file lives in core/src/main/proto/
protobuf {
    protoc {
        artifact = "com.google.protobuf:protoc:4.31.1"
    }
    generateProtoTasks {
        all().forEach { task ->
            task.builtins {
                create("java")
            }
        }
    }
}

dependencies {
    // Protobuf runtime
    implementation("com.google.protobuf:protobuf-kotlin:4.31.1")

    // Unit testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    testImplementation("com.google.protobuf:protobuf-kotlin:4.31.1")
}
