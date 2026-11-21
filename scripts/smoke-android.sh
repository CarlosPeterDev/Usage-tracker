#!/usr/bin/env bash
set -euo pipefail
app=com.carlos.data_usage_tracker
window="$(mktemp)"
trap 'rm -f "$window"' EXIT

wait_for_text() {
  local label="$1"
  for attempt in {1..12}; do
    adb shell rm -f /sdcard/tracker-window.xml
    if adb shell uiautomator dump /sdcard/tracker-window.xml >/dev/null 2>&1 &&
       adb exec-out cat /sdcard/tracker-window.xml > "$window" &&
       grep -Fq "$label" "$window"; then
      return
    fi
    sleep 2
  done
  adb logcat -d -s AndroidRuntime:E flutter:E
  echo "Missing UI text: $label" >&2
  return 1
}

adb install "$1"
adb shell am start -W -n "$app/.MainActivity"
wait_for_text 'Privacy &amp; Data'
read -r x y < <(python3 - "$window" <<'PYTHON'
import re
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1])
node = next(node for node in root.iter("node")
            if "Continue" in (node.get("text"), node.get("content-desc")))
left, top, right, bottom = map(int, re.findall(r"\d+", node.attrib["bounds"]))
print((left + right) // 2, (top + bottom) // 2)
PYTHON
)
adb shell input tap "$x" "$y"
wait_for_text 'Open Usage access settings'
adb shell am force-stop "$app"
adb shell am start -W -n "$app/.MainActivity"
wait_for_text 'Open Usage access settings'
echo 'Android 7 verified privacy onboarding, acknowledgement persistence, and the permission screen.'
