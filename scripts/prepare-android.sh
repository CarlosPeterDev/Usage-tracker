#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
scaffold="$(mktemp -d)"
trap 'rm -rf "$scaffold"' EXIT
flutter create --platforms=android --org com.carlos --project-name data_usage_tracker --no-pub "$scaffold/data_usage_tracker"
gradle_file="$scaffold/data_usage_tracker/android/app/build.gradle.kts"
grep -q 'compileSdk = flutter.compileSdkVersion' "$gradle_file"
grep -q 'targetSdk = flutter.targetSdkVersion' "$gradle_file"
sed -i -e 's/compileSdk = flutter.compileSdkVersion/compileSdk = 37/' \
  -e 's/targetSdk = flutter.targetSdkVersion/targetSdk = 37/' "$gradle_file"
cat >> "$gradle_file" <<'GRADLE'

dependencies {
    implementation("com.google.android.libraries.ads.mobile.sdk:ads-mobile-sdk:1.6.0")
}
GRADLE
if [[ -n "${TRACKER_KEYSTORE_PATH:-}" ]]; then
    test -s "$TRACKER_KEYSTORE_PATH"
    sed -i 's/signingConfig = signingConfigs.getByName("debug")/signingConfig = signingConfigs.getByName("upload")/' "$gradle_file"
    grep -q 'signingConfig = signingConfigs.getByName("upload")' "$gradle_file"
    cat >> "$gradle_file" <<'GRADLE'

android {
    signingConfigs {
        maybeCreate("upload").apply {
            storeFile = file(System.getenv("TRACKER_KEYSTORE_PATH"))
            storePassword = System.getenv("TRACKER_STORE_PASSWORD")
            keyAlias = System.getenv("TRACKER_KEY_ALIAS")
            keyPassword = System.getenv("TRACKER_KEY_PASSWORD")
        }
    }
}
GRADLE
    # Register the signing config before the template's release build type uses it.
    python3 - "$gradle_file" <<'PYTHON'
from pathlib import Path
import sys

path = Path(sys.argv[1])
gradle, signing = path.read_text().rsplit("android {", 1)
signing = signing.rsplit("}", 1)[0]
path.write_text(gradle.replace("android {", "android {" + signing, 1))
PYTHON
fi
mkdir -p android
cp -R "$scaffold/data_usage_tracker/android/." android/
cp android_overlay/AndroidManifest.xml android/app/src/main/
cp android_overlay/kotlin/*.kt android/app/src/main/kotlin/com/carlos/data_usage_tracker/
cp -R android_overlay/res/. android/app/src/main/res/
