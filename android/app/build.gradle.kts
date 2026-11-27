import java.net.URI
import java.security.MessageDigest

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

// On-device speech recognition (offline fallback): the pinned whisper.cpp release, downloaded once,
// checked against its SHA-256 and unpacked for the NDK build in src/main/cpp.
val whisperVersion = "1.9.5"
val whisperArchiveSha256 = "ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720"
val whisperThirdParty = rootProject.layout.buildDirectory.dir("third_party")
val whisperSourceDir = whisperThirdParty.map { it.dir("whisper.cpp-$whisperVersion") }

abstract class DownloadVerified : DefaultTask() {
    @get:Input abstract val url: Property<String>
    @get:Input abstract val sha256: Property<String>
    @get:OutputFile abstract val destination: RegularFileProperty

    @TaskAction
    fun download() {
        val target = destination.get().asFile
        val expected = sha256.get()
        if (target.isFile && sha256Of(target) == expected) return
        target.parentFile.mkdirs()
        val partial = File(target.parentFile, target.name + ".part")
        URI(url.get()).toURL().openStream().use { input -> partial.outputStream().use { input.copyTo(it) } }
        val actual = sha256Of(partial)
        if (actual != expected) {
            partial.delete()
            throw GradleException("${url.get()} has SHA-256 $actual, expected $expected. Nothing was unpacked.")
        }
        target.delete()
        if (!partial.renameTo(target)) throw GradleException("Could not move the download to $target.")
    }

    private fun sha256Of(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}

val downloadWhisper by tasks.registering(DownloadVerified::class) {
    description = "Downloads the pinned whisper.cpp release and checks its SHA-256."
    url.set("https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v$whisperVersion.tar.gz")
    sha256.set(whisperArchiveSha256)
    destination.set(whisperThirdParty.map { it.file("whisper.cpp-$whisperVersion.tar.gz") })
}

val unpackWhisper by tasks.registering(Sync::class) {
    description = "Unpacks the verified whisper.cpp sources for the NDK build."
    from(downloadWhisper.flatMap { it.destination }.map { tarTree(resources.gzip(it.asFile)) }) {
        eachFile { relativePath = RelativePath(true, *relativePath.segments.drop(1).toTypedArray()) }
        includeEmptyDirs = false
    }
    into(whisperSourceDir)
}

android {
    namespace = "com.voiceink.keyboard"
    compileSdk = 36
    ndkVersion = "27.1.12297006"

    defaultConfig {
        applicationId = "com.voiceink.keyboard"
        // Android 10: covers every Samsung and Pixel phone still receiving updates.
        minSdk = 29
        targetSdk = 36
        versionCode = gitVersionFields.getValue("versionCode").toInt()
        versionName = gitVersionFields.getValue("versionName")

        // Phones (64- and 32-bit ARM) and x86_64 emulators.
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DWHISPER_SOURCE_DIR=${whisperSourceDir.get().asFile.absolutePath}",
                    "-DANDROID_STL=c++_static",
                )
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
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
// The NDK build reads the whisper.cpp sources at configure time.
tasks.matching { it.name.startsWith("configureCMake") || it.name.startsWith("buildCMake") }
    .configureEach { dependsOn(unpackWhisper) }

dependencies {
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.play.services.code.scanner)

    testImplementation(libs.junit)
    // The android.jar stubs of org.json throw in JVM tests; use the real implementation there.
    testImplementation(libs.json)
}
