# Used by ndk-build (through Gradle's externalNativeBuild). ABIs come from
# android/app/build.gradle.kts (abiFilters).
APP_OPTIM := release
APP_PLATFORM := android-26
APP_CFLAGS := -O3
# 16 KB page size support (Android 15+ devices).
APP_SUPPORT_FLEXIBLE_PAGE_SIZES := true
