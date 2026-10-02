#!/system/bin/sh

DIR="$(dirname "$0")"
OUT="$DIR/webroot/status.json"
DATA=/data/adb/force_webview

VER=$(grep ^version= "$DIR/module.prop" 2>/dev/null | cut -d= -f2)

ACT=0
APPSTR=""
for p in $(ls "$DATA/backup" 2>/dev/null); do
    st=$(cat "$DATA/state/$p" 2>/dev/null)
    if [ "$st" = "active" ]; then
        ACT=$((ACT+1)); APPSTR="$APPSTR\"$p\":true,"
    elif [ -z "$st" ] && [ -n "$(ls -A "$DATA/backup/$p" 2>/dev/null)" ]; then
        ACT=$((ACT+1)); APPSTR="$APPSTR\"$p\":true,"
    fi
done
APPSTR=$(printf '%s' "$APPSTR" | sed 's/,$//')

# 本机已安装的第三方应用（供 WebUI 过滤未安装的配置项）
INSTSTR=""
for p in $(pm list packages -3 2>/dev/null | sed 's/^package://'); do
    INSTSTR="$INSTSTR\"$p\","
done
INSTSTR=$(printf '%s' "$INSTSTR" | sed 's/,$//')

ROOT="未知"
if [ -d /data/adb/ksu ]; then
    KVER=$(ksud -V 2>/dev/null | awk '{print $2}')
    [ -n "$KVER" ] && ROOT="KernelSU $KVER"
elif [ -d /data/adb/magisk ]; then
    ROOT="Magisk $(magisk -v 2>/dev/null | head -1)"
elif [ -d /data/adb/ap ]; then
    ROOT="APatch"
fi

WV=$(dumpsys webviewupdate 2>/dev/null | grep -m1 'Current WebView package' | grep -oE '[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+' | head -1)
DEV=$(getprop ro.product.marketname)
[ -z "$DEV" ] && DEV=$(getprop ro.product.model)
AND=$(getprop ro.build.version.release)
BK=$(du -sk "$DATA/backup" 2>/dev/null | cut -f1)
[ -z "$BK" ] && BK=0
set -- $(df -k /data 2>/dev/null | tail -1)
DT=${2:-0}
DU=${3:-0}

printf '{"version":"%s","active":%d,"webview":"%s","device":"%s","android":"%s","root":"%s","backupKB":%d,"dataUsedKB":%s,"dataTotalKB":%s,"installed":[%s],"apps":{%s}}\n' \
    "$VER" "$ACT" "$WV" "$DEV" "$AND" "$ROOT" "$BK" "$DU" "$DT" "$INSTSTR" "$APPSTR" > "$OUT"
chmod 644 "$OUT"
