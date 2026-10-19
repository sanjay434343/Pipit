# ==============================================================================
# ProGuard / R8 Rules for Pipit
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. General Optimization & Attributes
# ------------------------------------------------------------------------------
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod
-keepattributes SourceFile,LineNumberTable
-keepattributes Exceptions

# Keep all native JNI methods (critical for C++ LiteRT, TFLite, and ML libraries)
-keepclasseswithmembernames class * {
    native <methods>;
}

# ------------------------------------------------------------------------------
# 2. Flutter Framework & Core Plugins
# ------------------------------------------------------------------------------
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep App's MainActivity, FlutterActivity, and MethodChannel handlers
-keep class com.example.pipit.** { *; }

# ------------------------------------------------------------------------------
# 3. AI & LiteRT / TensorFlow Lite / Edge AI (flutter_edge_ai & litertlm)
# ------------------------------------------------------------------------------
# Keep Google LiteRT (LiteRT-LM & Edge AI)
-keep class com.google.ai.edge.litert.** { *; }
-keep interface com.google.ai.edge.litert.** { *; }
-dontwarn com.google.ai.edge.litert.**

# Keep TensorFlow Lite Core & JNI bindings
-keep class org.tensorflow.lite.** { *; }
-keep interface org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**

-keep class com.google.android.gms.tflite.** { *; }
-dontwarn com.google.android.gms.tflite.**

# MediaPipe & Protobuf runtime classes
-keep class com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.mediapipe.**
-dontwarn com.google.protobuf.**

# ------------------------------------------------------------------------------
# 4. Google ML Kit (Text Recognition / Vision)
# ------------------------------------------------------------------------------
-keep class com.google.mlkit.** { *; }
-keep interface com.google.mlkit.** { *; }
-keep class com.google.android.gms.vision.** { *; }
-keep class com.google.android.gms.tasks.** { *; }
-keep class com.google.android.gms.common.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**

# ------------------------------------------------------------------------------
# 5. Database & Local Storage (sqflite)
# ------------------------------------------------------------------------------
-keep class com.tekartik.sqflite.** { *; }
-keep class androidx.sqlite.** { *; }
-keep class androidx.room.** { *; }
-dontwarn com.tekartik.sqflite.**

# ------------------------------------------------------------------------------
# 6. File Provider, Permissions & System Handlers
# ------------------------------------------------------------------------------
-keep class androidx.core.content.FileProvider { *; }
-keep class com.baseflow.permissionhandler.** { *; }
-keep class com.mr.flutter.plugin.filepicker.** { *; }
-dontwarn com.baseflow.permissionhandler.**
-dontwarn com.mr.flutter.plugin.filepicker.**

# ------------------------------------------------------------------------------
# 7. Kotlin Coroutines & Okio / Networking Suppressions
# ------------------------------------------------------------------------------
-dontwarn kotlinx.coroutines.**
-dontwarn okio.**
-dontwarn org.bouncycastle.jsse.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
-dontwarn javax.annotation.**
-dontwarn org.checkerframework.**

# ------------------------------------------------------------------------------
# 8. Play Core Deferred & XML Stream Suppressions (Play Core & Apache Tika)
# ------------------------------------------------------------------------------
-dontwarn com.google.android.play.core.**
-dontwarn javax.xml.stream.**
-dontwarn org.apache.tika.**
-dontwarn androidx.window.**
-dontwarn androidx.media.**

# ------------------------------------------------------------------------------
# 9. SharedPreferences (shared_preferences_android)
# ------------------------------------------------------------------------------
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-dontwarn io.flutter.plugins.sharedpreferences.**

