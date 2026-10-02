#!/system/bin/sh
# 生成 WebUI 备份列表；仅列出含实际备份文件的应用，忽略 .restore-list 清单。
MODDIR="${0%/*}"
BACKUP_ROOT=/data/adb/force_webview/backup
OUT="$MODDIR/webroot/bk-list.txt"
TMP="$OUT.tmp.$$"

: > "$TMP" || exit 1
for dir in "$BACKUP_ROOT"/*; do
    [ -d "$dir" ] || continue
    pkg=${dir##*/}
    # .restore-list 只是恢复清单，不代表存在备份内容。
    found=$(find "$dir" -type f ! -name '.restore-list' -print -quit 2>/dev/null)
    [ -n "$found" ] || continue
    size=$(du -sm "$dir" 2>/dev/null | cut -f1)
    [ -n "$size" ] || size=0
    printf '%s|%s\n' "$pkg" "$size" >> "$TMP"
done
mv "$TMP" "$OUT" && chmod 644 "$OUT"
