#!/bin/bash
# 치지직 점검.app 빌드.
#   ./scripts/build.sh          빌드만
#   ./scripts/build.sh install  빌드 후 /Applications 에 설치
#   ./scripts/build.sh zip      빌드 후 릴리스용 build/ChzzkCheck-<버전>-arm64.zip 생성
set -euo pipefail
cd "$(dirname "$0")/.."

NAME_APP="치지직 점검.app"
APP="build/$NAME_APP"
C="$APP/Contents"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources/ko.lproj"

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
    -o "$C/MacOS/ChzzkCheck" src/ChzzkCheck.swift
cp src/Info.plist "$C/Info.plist"
# 빌드 번호는 빌드 시각
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$C/Info.plist"

# 아이콘: macOS 26 이상은 Assets.car(유리 질감), 그 이전은 AppIcon.icns
xcrun actool src/AppIcon.icon --compile "$C/Resources" --app-icon AppIcon --platform macosx \
    --minimum-deployment-target 14.0 --output-partial-info-plist build/icon.plist >/dev/null

# 점검 로직은 check.mjs 한 곳에 있고, 앱은 이것을 실행해 결과를 보여 준다
cp src/check.mjs "$C/Resources/check.mjs"
# 메뉴 등 시스템이 넣는 글자를 한국어로 나오게 한다
printf '"CFBundleDisplayName" = "치지직 점검";\n"CFBundleName" = "치지직 점검";\n' > "$C/Resources/ko.lproj/InfoPlist.strings"

codesign --force --sign - "$APP"
echo "빌드 완료: $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x ChzzkCheck 2>/dev/null || true
    rm -rf "/Applications/$NAME_APP"
    cp -R "$APP" /Applications/
    echo "설치 완료: /Applications/$NAME_APP"
fi

if [[ "${1:-}" == "zip" ]]; then
    # zip 안 구성: ChzzkCheck-<버전>/{치지직 점검.app, LICENSE}. 맥 확장 속성(._ 파일)은 뺀다
    VERSION=$(plutil -extract CFBundleShortVersionString raw src/Info.plist)
    NAME="ChzzkCheck-$VERSION"
    ZIP="build/$NAME-arm64.zip"
    rm -rf "build/$NAME" "$ZIP"
    mkdir "build/$NAME"
    ditto --norsrc --noextattr "$APP" "build/$NAME/$NAME_APP"
    cp LICENSE "build/$NAME/"
    (cd build && ditto -c -k --norsrc --noextattr --keepParent "$NAME" "$NAME-arm64.zip")
    rm -rf "build/$NAME"
    echo "zip 완료: $ZIP"
    shasum -a 256 "$ZIP"
fi
