# Places 5.1.1 documented R8 full-mode workaround; remove when upgrading past
# the affected release and verifying the signed release build.
-keepclassmembers class com.google.android.libraries.places.internal.** {
    <init>();
}
