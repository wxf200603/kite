# Kite — Build Guide (Trae)

This file documents how to trigger the CI skeleton build from Trae and how to
produce a full release build locally.

## Trigger the skeleton CI build from Trae

The repository ships a GitHub Actions workflow at
`.github/workflows/build-skeleton.yml`. It builds a **skeleton APK** (no native
`.so`) and uploads it as an artifact retained for 14 days.

To trigger it manually from Trae:

```bash
gh workflow run build-skeleton.yml --ref main
```

To watch the run and download the artifact:

```bash
gh run watch
gh run download <run-id> -n kite-skeleton-apk
```

> The skeleton APK is **not runnable** — it lacks `libllama.so` and
> `libquickjs.so`. It only validates that the Dart / Kotlin / resource layers
> compile and package. See [README-CI.md](./README-CI.md) for details.

## Skeleton vs full build

| Aspect | Skeleton (CI) | Full (local) |
| --- | --- | --- |
| Native `.so` (llama.cpp / QuickJS) | Excluded | Required in `jniLibs/arm64-v8a/` |
| Local LLM inference | No | Yes |
| ToolPkg / QuickJS execution | No | Yes |
| Trigger | `gh workflow run build-skeleton.yml --ref main` | Android Studio or `flutter build apk` |
| Gradle flag | `-PkiteSkeletonBuild=true` | (none) |

## Full arm64-v8a release build (local)

Prerequisites:
- Flutter `>= 3.44.9` (Dart `^3.12.1`)
- Android Studio with NDK
- Precompiled `libllama.so` and `libquickjs.so` for `arm64-v8a`

Steps:

```bash
# 1. Place precompiled native libs
mkdir -p android/app/src/main/jniLibs/arm64-v8a
cp libllama.so libquickjs.so android/app/src/main/jniLibs/arm64-v8a/

# 2. Resolve dependencies
flutter pub get

# 3. Build release APK (arm64-v8a only)
flutter build apk --release --target-platform android-arm64
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

Do **not** pass `-PkiteSkeletonBuild=true` for a full build — that flag skips
native compilation and is for CI skeleton builds only.
