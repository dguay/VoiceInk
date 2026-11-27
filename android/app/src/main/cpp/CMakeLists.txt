# On-device speech recognition: whisper.cpp (and its bundled ggml) linked statically into one JNI
# library. Gradle downloads and verifies the pinned whisper.cpp release (see app/build.gradle.kts)
# and passes its directory as WHISPER_SOURCE_DIR.
cmake_minimum_required(VERSION 3.22.1)
project(voiceink_whisper C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if (NOT WHISPER_SOURCE_DIR OR NOT EXISTS "${WHISPER_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "WHISPER_SOURCE_DIR must point at the whisper.cpp sources (got '${WHISPER_SOURCE_DIR}').")
endif ()

# Library only, CPU only, statically linked; portable code for every phone of the ABI.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(WHISPER_CURL OFF CACHE BOOL "" FORCE)
set(WHISPER_SDL2 OFF CACHE BOOL "" FORCE)
set(WHISPER_ALL_WARNINGS OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)

add_subdirectory(${WHISPER_SOURCE_DIR} whisper EXCLUDE_FROM_ALL)

# Debug builds are what runs on emulators and test phones, and unoptimized ggml takes minutes per
# dictation: optimize the engine in every build type (a later -O wins over the toolchain's -O0).
foreach (engine_target IN ITEMS whisper ggml ggml-base ggml-cpu)
    if (TARGET ${engine_target})
        target_compile_options(${engine_target} PRIVATE -O3 -DNDEBUG)
    endif ()
endforeach ()

add_library(voiceink_whisper SHARED whisper_jni.cpp)
target_link_libraries(voiceink_whisper PRIVATE whisper log)
target_compile_options(voiceink_whisper PRIVATE -fvisibility=hidden)
if (NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_link_options(voiceink_whisper PRIVATE -Wl,--gc-sections -Wl,--exclude-libs,ALL)
endif ()
