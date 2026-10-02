#!/system/bin/sh

# uninstall.sh — 按 config dirs 还原备份后清理

DATA_ROOT=/data/adb/force_webview
CONFIG_FILE=$DATA_ROOT/config.json
BACKUP_ROOT=$DATA_ROOT/backup
LOCK_DIR=$DATA_ROOT/.lockdir
UNRESTORED_ROOT=${DATA_ROOT}.unrestored
TAB=$(printf '\t')

parse_config() {
    awk '
    function emit() {
        if (pkg != "") {
            for (i=1; i<=dcount; i++) print pkg "\t" dirs[i]
            if (dcount == 0) print pkg "\t"
        }
    }
    {
        line = $0
        if (match(line, /^    "[^"]+": \{$/)) {
            emit()
            pkg = line
            gsub(/^    "/, "", pkg); gsub(/": \{$/, "", pkg)
            dcount = 0; indirs = 0
        }
        else if (pkg != "") {
            if (index(line, "\"dirs\"") > 0) { indirs = 1 }
            else if (indirs && match(line, /^        "[^"]*",?$/)) {
                d = line
                gsub(/^        "/, "", d); gsub(/",?$/, "", d)
                dirs[++dcount] = d
            }
            else if (line ~ /^[ ]*\]/) { indirs = 0 }
        }
    }
    END { emit() }
    ' "$CONFIG_FILE"
}

restore_one() {
    pkg="$1"; rel="$2"
    [ -n "$pkg" ] && [ -n "$rel" ] || return 0
    [ -e "$BACKUP_ROOT/$pkg/$rel" ] || return 0
    [ -d "/data/data/$pkg" ] || { echo "跳过 $pkg/$rel（应用数据目录不存在）"; return 0; }

    dst="/data/data/$pkg/$rel"
    if [ -e "$dst" ]; then
        chmod 755 "$dst" 2>/dev/null
        rm -rf "$dst" 2>/dev/null
    fi
    if [ ! -e "$dst" ]; then
        mkdir -p "$(dirname "$dst")"
        if mv "$BACKUP_ROOT/$pkg/$rel" "$dst" 2>/dev/null; then
            appu=$(stat -c "%U:%G" "/data/data/$pkg" 2>/dev/null)
            ctx=$(ls -Zd "/data/data/$pkg" 2>/dev/null | awk '{print $1}')
            [ -n "$appu" ] && chown -R "$appu" "$dst" 2>/dev/null
            [ -n "$ctx" ] && chcon -R "$ctx" "$dst" 2>/dev/null
            echo "已还原 $pkg/$rel"
        else
            echo "还原失败 $pkg/$rel"
        fi
    fi
}

restore_all() {
    [ -f "$CONFIG_FILE" ] && parse_config | while IFS="$TAB" read -r pkg rel; do restore_one "$pkg" "$rel"; done
    for manifest in "$BACKUP_ROOT"/*/.restore-list; do
        [ -f "$manifest" ] || continue
        pkg=$(basename "$(dirname "$manifest")")
        while IFS= read -r rel; do restore_one "$pkg" "$rel"; done < "$manifest"
    done
}

mkdir -p "$DATA_ROOT"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$pid" ] && [ ! -d "/proc/$pid" ]; then
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" 2>/dev/null || { echo "模块正在运行，请稍后再试"; exit 1; }
    else
        echo "模块正在运行，请稍后再试"
        exit 1
    fi
fi

echo "开始还原备份..."
restore_all

# 应用数据目录不存在或恢复失败时，绝不随卸载删除仍在 backup 中的数据。
if [ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]; then
    mkdir -p "$UNRESTORED_ROOT"
    for pkgdir in "$BACKUP_ROOT"/*; do
        [ -d "$pkgdir" ] || continue
        pkg=$(basename "$pkgdir")
        rm -rf "$UNRESTORED_ROOT/$pkg"
        mv "$pkgdir" "$UNRESTORED_ROOT/$pkg" 2>/dev/null && echo "未恢复的备份已保留：$UNRESTORED_ROOT/$pkg"
    done
fi

echo "删除 /data/adb/force_webview ..."
rm -rf "$DATA_ROOT"
echo "卸载完成（未恢复备份如有，已保留在 $UNRESTORED_ROOT）"
