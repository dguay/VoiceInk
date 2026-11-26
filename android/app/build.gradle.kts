plugins {
    alias(libs.plugins.android.application)
}

// Version from the fork's Git history (scripts/version.sh): a later commit gets a greater
// versionCode, and versionName carries the commit SHA.
val gitVersion = providers.exec {
    commandLine("bash", rootDir.resolve("scripts/version.sh").path, rootDir.path)
    isIgnoreExitValue = true
}
val gitVersionFields: Map<String, String> = run {
    if (gitVersion.result.get().exitValue != 0) {
        throw GradleException(gitVersion.standardError.asText.get().trim().ifEmpty { "scripts/version.sh failed." })
    }
    gitVersion.standardOutput.asText.get().lines()
        .filter { it.contains('=') }
        .associate { it.substringBefore('=') to it.substringAfter('=') }
}

// Release signing: scripts/build-release.sh materializes the Keychain key into temporary files
// and passes only their paths. Without them, debug builds, tests and lint still work, and any
// release build stops before compiling.
val releaseKeystoreFile = providers.environmentVariable("VOICEINK_ANDROID_KEYSTORE_FILE").orNull
val releaseKeystorePasswordFile = providers.environmentVariable("VOICEINK_ANDROID_KEYSTORE_PASSWORD_FILE").orNull
val releaseSigningAvailable = releaseKeystoreFile != null && releaseKeystorePasswordFile != null &&
    file(releaseKeystoreFile).isFile && file(releaseKeystorePasswordFile).isFile

android {
    namespace = "com.voiceink.keyboard"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.voiceink.keyboard"
        // Android 10: covers every Samsung and Pixel phone still receiving updates.
        minSdk = 29
        targetSdk = 36
        versionCode = gitVersionFields.getValue("versionCode").toInt()
        versionName = gitVersionFields.getValue("versionName")
    }

    signingConfigs {
        if (releaseSigningAvailable) {
            create("release") {
                storeFile = file(releaseKeystoreFile!!)
                storePassword = file(releaseKeystorePasswordFile!!).readText()
                keyAlias = "voiceink"
                keyPassword = storePassword
                storeType = "PKCS12"
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (releaseSigningAvailable) {
                signingConfig = signingConfigs.getByName("release")
            }
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

val checkReleaseSigning by tasks.registering {
    description = "Stops release builds that lack the Keychain release key."
    val signingAvailable = releaseSigningAvailable
    doLast {
        if (!signingAvailable) {
            throw GradleException(
                "Release builds are signed with the release key from the Mac's Keychain. " +
                    "Build with android/scripts/build-release.sh (it sets VOICEINK_ANDROID_KEYSTORE_FILE " +
                    "and VOICEINK_ANDROID_KEYSTORE_PASSWORD_FILE). If the key is missing, create or import it " +
                    "with android/scripts/release-key.sh (see android/README.md).",
            )
        }
    }
}
tasks.named { it == "preReleaseBuild" }.configureEach { dependsOn(checkReleaseSigning) }

dependencies {
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.play.services.code.scanner)

    testImplementation(libs.junit)
    // The android.jar stubs of org.json throw in JVM tests; use the real implementation there.
    testImplementation(libs.json)
}
