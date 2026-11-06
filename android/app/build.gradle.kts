plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "com.voiceink.keyboard"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.voiceink.keyboard"
        // Android 10: covers every Samsung and Pixel phone still receiving updates.
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    lint {
        abortOnError = true
        warningsAsErrors = false
    }
}

dependencies {
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.play.services.code.scanner)

    testImplementation(libs.junit)
    // The android.jar stubs of org.json throw in JVM tests; use the real implementation there.
    testImplementation(libs.json)
}
