cmake_minimum_required(VERSION 3.22.1)

project("llama_jni")

# llama.cpp sources are not vendored. To build, provide llama.cpp via
# LLAMA_CPP_SOURCE_DIR (clone https://github.com/ggml-org/llama.cpp.git).
# The prebuilt libLlamaWrapper.so is expected under jniLibs for release builds.
set(LLAMA_CPP_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/llama.cpp-src" CACHE PATH "Path to llama.cpp sources")

if(EXISTS "${LLAMA_CPP_SOURCE_DIR}/CMakeLists.txt")
    set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)

    add_subdirectory("${LLAMA_CPP_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/llama-build" EXCLUDE_FROM_ALL)

    add_library(
        LlamaWrapper
        SHARED
        src/main/cpp/llama_jni_stub.cpp
    )

    target_compile_definitions(LlamaWrapper PRIVATE OPERIT_HAS_LLAMA_CPP=1)
    target_include_directories(LlamaWrapper PRIVATE
        "${LLAMA_CPP_SOURCE_DIR}"
        "${LLAMA_CPP_SOURCE_DIR}/common"
        "${LLAMA_CPP_SOURCE_DIR}/include"
        "${LLAMA_CPP_SOURCE_DIR}/ggml/include"
        "${LLAMA_CPP_SOURCE_DIR}/vendor"
    )
    target_link_libraries(LlamaWrapper llama llama-common android log)
    target_link_options(LlamaWrapper PRIVATE "-Wl,-z,max-page-size=16384")
else()
    message(WARNING "llama.cpp sources not found at ${LLAMA_CPP_SOURCE_DIR}. "
        "Native build skipped; provide prebuilt libLlamaWrapper.so.")
endif()
