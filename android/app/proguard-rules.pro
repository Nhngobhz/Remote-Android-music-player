# youtubedl-android reads yt-dlp's output with Jackson and unpacks Python with Commons
# Compress. Both find classes by reflection, so R8 must not rename or strip them.
-keep class com.yausername.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-keep class org.apache.commons.compress.archivers.zip.** { *; }
-dontwarn com.fasterxml.jackson.databind.**
