# youtubedl-android shells out to a bundled Python/yt-dlp binary and maps its
# JSON output onto these model classes; keep them intact for R8.
-keep class com.yausername.youtubedl_android.** { *; }
-keep class com.yausername.ffmpeg.** { *; }

# Room generates code at compile time that R8 can otherwise strip.
-keep class androidx.room.** { *; }
-keep @androidx.room.Entity class * { *; }
-dontwarn org.jetbrains.annotations.**
