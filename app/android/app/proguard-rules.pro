## Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

## Google Play Services / Firebase
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }

## Google Mobile Ads
-keep class com.google.android.gms.ads.** { *; }

## Google Play Core (deferred components)
-dontwarn com.google.android.play.core.**
