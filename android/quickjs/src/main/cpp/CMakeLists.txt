cmake_minimum_required(VERSION 3.22.1)

project(quickjsjni)

# QuickJS sources are not vendored in this repository. To build the native
# library, clone QuickJS (https://github.com/bellard/quickjs) into
# `src/main/cpp/quickjs-src/` (or point QUICKJS_SRC_DIR at it) so that
# quickjs.h and the *.c sources are available. The prebuilt libquickjsjni.so
# is expected to be shipped under app/src/main/jniLibs/<abi>/ for release
# builds.
set(QUICKJS_SRC_DIR "${CMAKE_CURRENT_LIST_DIR}/quickjs-src" CACHE PATH "Path to QuickJS sources")

if(EXISTS "${QUICKJS_SRC_DIR}/quickjs.c")
    file(READ "${QUICKJS_SRC_DIR}/VERSION" QUICKJS_VERSION_RAW)
    string(STRIP "${QUICKJS_VERSION_RAW}" QUICKJS_VERSION)

    add_library(
        quickjsjni
        SHARED
        quickjs_jni.cpp
        ${QUICKJS_SRC_DIR}/cutils.c
        ${QUICKJS_SRC_DIR}/dtoa.c
        ${QUICKJS_SRC_DIR}/libregexp.c
        ${QUICKJS_SRC_DIR}/libunicode.c
        ${QUICKJS_SRC_DIR}/quickjs.c
    )

    target_compile_definitions(
        quickjsjni
        PRIVATE
        _GNU_SOURCE
        CONFIG_VERSION="${QUICKJS_VERSION}"
        NDEBUG
    )

    target_compile_options(
        quickjsjni
        PRIVATE
        -O3
        -fwrapv
        -funsigned-char
        -Wall
        -Wextra
        -Wno-sign-compare
        -Wno-missing-field-initializers
        -Wno-unused-parameter
        -Wwrite-strings
        -Wchar-subscripts
    )

    target_include_directories(
        quickjsjni
        PRIVATE
        "${QUICKJS_SRC_DIR}"
    )

    set_target_properties(
        quickjsjni
        PROPERTIES
        C_STANDARD 11
        C_STANDARD_REQUIRED ON
        CXX_STANDARD 17
        CXX_STANDARD_REQUIRED ON
    )

    target_link_libraries(
        quickjsjni
        android
        log
        m
    )
else()
    message(WARNING "QuickJS sources not found at ${QUICKJS_SRC_DIR}. "
        "Native library build skipped; provide prebuilt libquickjsjni.so.")
endif()
