plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "dev.touchbridge.wear"
    compileSdk = 37

    defaultConfig {
        applicationId = "dev.touchbridge.wear"
        minSdk = 30  // Wear OS 3+
        targetSdk = 37
        versionCode = 1
        versionName = "0.1.0"
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // Wear OS Compose
    implementation(platform("androidx.compose:compose-bom:2026.08.00"))
    implementation("androidx.wear.compose:compose-material:1.4.0")
    implementation("androidx.wear.compose:compose-foundation:1.3.0")
    implementation("androidx.activity:activity-compose:1.13.0")

    // Wearable Data Layer API
    implementation("com.google.android.gms:play-services-wearable:18.1.0")

    // Lifecycle
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.7.0")
    implementation("androidx.core:core-ktx:1.12.0")

    // Haptic
    implementation("androidx.wear:wear:1.3.0")
}
