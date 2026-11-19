# The on-device downloader (youtubedl-android) unpacks its runtime with Apache Commons Compress and
# reads yt-dlp's JSON with Jackson. Both build classes by reflection. R8 renames or strips what it
# cannot see being called, and the engine then crashes at first use ("class ... is not a concrete
# class"), so these are kept as they are.
-keep class com.yausername.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-keep class org.apache.commons.** { *; }
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod, RuntimeVisibleAnnotations
-dontwarn com.fasterxml.jackson.databind.**
-dontwarn java.beans.**
-dontwarn org.w3c.dom.bootstrap.**
-dontwarn org.apache.commons.**
