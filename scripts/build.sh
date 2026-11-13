#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
project_root="$PWD"
build_root="$project_root/.build"
app="$build_root/AWS 余量.app"
arch="$(uname -m)"
case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$build_root/module-cache" "$project_root/dist"

# Map build paths out of the distributed executable. No AWS configuration is read.
xcrun swiftc -O -target "$arch-apple-macosx14.0" \
  -module-cache-path "$build_root/module-cache" \
  -file-prefix-map "$project_root=/Source" \
  -debug-prefix-map "$project_root=/Source" \
  -file-compilation-dir /Source \
  Sources/AWSCredit.swift -o "$app/Contents/MacOS/AWSCredit"
xcrun swiftc -O Sources/Icon.swift -o "$build_root/make-icon"
"$build_root/make-icon" "$build_root/AppIcon.iconset"
iconutil -c icns "$build_root/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.kamona25.aws-credit-menubar</string>
<key>CFBundleExecutable</key><string>AWSCredit</string>
<key>CFBundleName</key><string>AWS 余量</string>
<key>CFBundleDisplayName</key><string>AWS 余量</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.4.2</string>
<key>CFBundleVersion</key><string>7</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp LICENSE "$app/Contents/Resources/LICENSE"
codesign --force --sign - --timestamp=none "$app"

# zipfile records the app's relative paths and executable permissions, without xattrs.
python3 - "$app" "$project_root/dist/AWS-Credit-Menubar-macOS-$arch.zip" <<'PY'
import sys
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
app, output = map(Path, sys.argv[1:])
with ZipFile(output, 'w', compression=ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob('*')):
        if path.is_file():
            archive.write(path, path.relative_to(app.parent))
print(output.name)
PY
echo "Built .build/AWS 余量.app; nothing installed or launched."

