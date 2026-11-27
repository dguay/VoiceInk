// JNI bridge for com.voiceink.keyboard.offline.WhisperNative: load a ggml Whisper model, transcribe
// 16 kHz mono float samples, free the model. Text is returned as UTF-8 bytes so Kotlin decodes it
// (JNI's NewStringUTF expects modified UTF-8 and rejects emoji).
#include <jni.h>
#include <android/log.h>

#include <algorithm>
#include <string>
#include <thread>

#include "whisper.h"

namespace {

constexpr const char *kTag = "VoiceInkWhisper";

void log_warnings(ggml_log_level level, const char *text, void * /*user_data*/) {
    if (level >= GGML_LOG_LEVEL_WARN) __android_log_write(ANDROID_LOG_WARN, kTag, text);
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_voiceink_keyboard_offline_WhisperNative_initContext(JNIEnv *env, jobject /*thiz*/, jstring model_path) {
    whisper_log_set(log_warnings, nullptr);
    const char *path = env->GetStringUTFChars(model_path, nullptr);
    if (path == nullptr) return 0;
    whisper_context_params params = whisper_context_default_params();
    params.use_gpu = false;
    whisper_context *ctx = whisper_init_from_file_with_params(path, params);
    env->ReleaseStringUTFChars(model_path, path);
    return reinterpret_cast<jlong>(ctx);
}

extern "C" JNIEXPORT void JNICALL
Java_com_voiceink_keyboard_offline_WhisperNative_freeContext(JNIEnv * /*env*/, jobject /*thiz*/, jlong handle) {
    auto *ctx = reinterpret_cast<whisper_context *>(handle);
    if (ctx != nullptr) whisper_free(ctx);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_voiceink_keyboard_offline_WhisperNative_transcribe(
    JNIEnv *env, jobject /*thiz*/, jlong handle, jfloatArray samples, jint threads) {
    auto *ctx = reinterpret_cast<whisper_context *>(handle);
    if (ctx == nullptr || samples == nullptr) return nullptr;

    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = std::max(1, static_cast<int>(threads));
    params.language = "auto";
    params.translate = false;
    params.no_context = true;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_special = false;
    params.print_timestamps = false;
    params.suppress_blank = true;

    jsize count = env->GetArrayLength(samples);
    jfloat *audio = env->GetFloatArrayElements(samples, nullptr);
    if (audio == nullptr) return nullptr;
    int status = whisper_full(ctx, params, audio, count);
    env->ReleaseFloatArrayElements(samples, audio, JNI_ABORT);
    if (status != 0) return nullptr;

    std::string text;
    const int segments = whisper_full_n_segments(ctx);
    for (int i = 0; i < segments; ++i) {
        const char *segment = whisper_full_get_segment_text(ctx, i);
        if (segment != nullptr) text += segment;
    }
    jbyteArray result = env->NewByteArray(static_cast<jsize>(text.size()));
    if (result == nullptr) return nullptr;
    env->SetByteArrayRegion(result, 0, static_cast<jsize>(text.size()), reinterpret_cast<const jbyte *>(text.data()));
    return result;
}
