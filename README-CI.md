# Kite CI — Skeleton Build

The GitHub Actions workflow `.github/workflows/build-skeleton.yml` produces a
**skeleton APK**. It is intentionally *not* a runnable build.

## What the skeleton APK contains

- Flutter engine + Dart AOT code
- All Kotlin/Java app code
- Android resources, manifest, launcher icon

## What the skeleton APK does **not** contain

- `libllama.so` (llama.cpp JNI)
- `libquickjs.so` (QuickJS JNI)
- Any other precompiled native `.so`

Because the native libraries are absent, the skeleton APK **cannot** perform
local LLM inference or run ToolPkg / QuickJS tool packages. It exists solely to
validate that the Dart + Kotlin + resource layers compile and package cleanly.

## How native compilation is skipped in CI

The `:llama` and `:quickjs` Gradle modules read the project property
`kiteSkeletonBuild`. When it equals `"true"`, their `externalNativeBuild`
blocks are omitted, so CMake / NDK is never invoked:

```
./gradlew assembleRelease -PkiteSkeletonBuild=true
```

The workflow passes this flag automatically. No source or CMake changes are
required for the local (full) build path.

## Producing a full (runnable) build locally

A full build requires the precompiled native `.so` files. They are **not**
shipped in the repository (they are large and ABI-specific).

1. Obtain or build `libllama.so` and `libquickjs.so` for `arm64-v8a`.
2. Place them under:
   ```
   android/app/src/main/jniLibs/arm64-v8a/
   ```
3. Open the project in Android Studio (or run from CLI):
   ```
   flutter pub get
   flutter build apk --release --target-platform android-arm64
   ```
4. Do **not** pass `-PkiteSkeletonBuild=true` for a full build.

## Artifact retention

CI artifacts are retained for **14 days**.

## Triggering the workflow

- Automatically on `push` to `main` / `master`.
- Manually via the GitHub Actions UI ("Run workflow"), or with `gh`:
  ```
  gh workflow run build-skeleton.yml --ref main
  ```
