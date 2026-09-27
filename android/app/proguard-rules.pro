-dontwarn java.awt.**
-dontwarn com.sun.jna.**

-keep class com.sun.jna.* { *; }
-keep class * extends com.sun.jna.* { *; }
-keepclassmembers class * extends com.sun.jna.* { public *; }

-keep class org.vosk.** { *; }

-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
