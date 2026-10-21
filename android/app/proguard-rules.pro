# R8 / ProGuard rules for the release build.

# The native tunnel (hev-socks5-tunnel) registers its JNI methods from JNI_OnLoad
# by class name (com/foxyvpn/app/vpn/HevSocks5Tunnel, see src/main/jni/Android.mk):
# neither the class nor its external methods may be renamed or removed.
-keep class com.foxyvpn.app.vpn.HevSocks5Tunnel { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}

# Components the system instantiates by name from the manifest (R8 keeps these
# through the AGP-generated rules; stated here so a rule change cannot drop them).
-keep class com.foxyvpn.app.MainActivity { *; }
-keep class com.foxyvpn.app.vpn.FoxyVpnService { *; }

# Flutter's embedding keeps what it needs through its own consumer rules.
-dontwarn io.flutter.embedding.**
