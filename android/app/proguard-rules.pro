# JNA looks up these Java classes, methods, and fields from native code. R8
# must not rename or remove them in release builds.
-dontwarn java.awt.**
-dontwarn com.sun.jna.**

-keep class com.sun.jna.* { *; }
-keep class * extends com.sun.jna.* { *; }
-keepclassmembers class * extends com.sun.jna.* { public *; }

# Vosk's Java/JNA bridge is also reached through native bindings.
-keep class org.vosk.** { *; }

# Android creates these assistant components by manifest/meta-data class name.
-keep class com.example.frontend.AgentVoiceInteractionService { *; }
-keep class com.example.frontend.AgentVoiceInteractionSessionService { *; }
-keep class com.example.frontend.AgentVoiceInteractionSession { *; }
-keep class com.example.frontend.AgentRecognitionService { *; }
-keep class com.example.frontend.AssistantPreviewActivity { *; }
-keep class com.example.frontend.HeyAgentNudgeView { *; }

# Preserve native method names and every type appearing in their descriptors.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
