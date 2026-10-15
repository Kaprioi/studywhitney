#!/bin/zsh
# Builds StudyWhitney.app and installs it to /Applications.
set -e
cd "${0:A:h}"
APP=build/StudyWhitney.app
rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources icon.iconset
swiftc -O -swift-version 5 main.swift -o $APP/Contents/MacOS/StudyWhitney -framework Cocoa -framework WebKit -framework EventKit
node icon.js ../studywhitney.html icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s icon-1024.png --out icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) icon-1024.png --out icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns icon.iconset -o $APP/Contents/Resources/AppIcon.icns
python3 make_app_page.py $APP/Contents/Resources/index.html
# Desktop Whitney shares the sprite code with the main page
node -e '
const fs=require("fs"); const h=fs.readFileSync("../studywhitney.html","utf8");
const sprite=h.slice(h.indexOf("const W = 32"), h.indexOf("function paint("));
fs.writeFileSync(process.argv[1], fs.readFileSync("pet.html","utf8").replace("/*SPRITE*/", sprite));
' $APP/Contents/Resources/pet.html
cat > $APP/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>StudyWhitney</string>
  <key>CFBundleDisplayName</key><string>StudyWhitney</string>
  <key>CFBundleIdentifier</key><string>local.studywhitney.app</string>
  <key>CFBundleExecutable</key><string>StudyWhitney</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemindersUsageDescription</key><string>StudyWhitney adds your to-dos to Reminders.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>StudyWhitney adds your to-dos to Reminders and checks them off when you finish them there.</string>
  <key>NSCalendarsUsageDescription</key><string>StudyWhitney puts your to-dos on your calendar.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>StudyWhitney puts your to-dos on your calendar.</string>
</dict></plist>
PLIST
codesign --force --deep -s - $APP
pkill -x StudyWhitney 2>/dev/null && sleep 1 || true
rm -rf /Applications/StudyWhitney.app && cp -R $APP /Applications/
echo "Installed /Applications/StudyWhitney.app"
