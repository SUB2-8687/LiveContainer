#!/bin/sh
# 빌드 전 en, ko 외의 모든 언어팩을 제거합니다.
# - *.lproj 폴더 (en.lproj, ko.lproj 제외)
# - *.xcstrings 내부의 en, ko 외 언어 항목
# - project.pbxproj 의 knownRegions (en, Base, ko 만 유지)
set -e

KEEP="en ko"

# 1) 다른 언어의 .lproj 폴더 삭제
find . -type d -name "*.lproj" -not -path "./.git/*" | while read -r dir; do
    lang=$(basename "$dir" .lproj)
    case " $KEEP Base " in
        *" $lang "*) ;;
        *) echo "Removing $dir"; rm -rf "$dir" ;;
    esac
done

# 2) xcstrings 에서 en, ko 외 언어 제거
find . -name "*.xcstrings" -not -path "./.git/*" | while read -r f; do
    python3 - "$f" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
keep = {"en", "ko"}
n = 0
for v in d.get("strings", {}).values():
    loc = v.get("localizations")
    if not loc:
        continue
    for lang in list(loc):
        if lang not in keep:
            del loc[lang]
            n += 1
open(p, "w", encoding="utf-8").write(json.dumps(d, indent=2, ensure_ascii=False, separators=(",", " : ")))
print(f"{p}: removed {n} localizations")
PY
done

# 3) pbxproj knownRegions 정리
python3 - <<'PY'
import re
p = "LiveContainer.xcodeproj/project.pbxproj"
t = open(p, encoding="utf-8").read()
m = re.search(r"knownRegions = \(\n(.*?)\t\t\t\);", t, re.S)
if m:
    t = t[:m.start(1)] + "\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t\tko,\n" + t[m.end(1):]
    open(p, "w", encoding="utf-8").write(t)
    print("knownRegions -> en, Base, ko")
PY
