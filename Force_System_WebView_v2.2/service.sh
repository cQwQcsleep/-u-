#!/system/bin/sh

MODDIR="${0%/*}"
DATA_ROOT=/data/adb/force_webview
CONFIG_FILE=$DATA_ROOT/config.json
BACKUP_ROOT=$DATA_ROOT/backup
STATE_ROOT=$DATA_ROOT/state
LOG_FILE=$DATA_ROOT/service.log
LOCK_DIR=$DATA_ROOT/.lockdir
LOG_MAX=131072
RESTORE_LIST=.restore-list
TAB=$(printf '\t')

FSW_MODE="${FSW_MODE:-${1:-normal}}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }

rotate_log() {
    [ -f "$LOG_FILE" ] || return 0
    local size
    size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt "$LOG_MAX" ]; then
        tail -c 32768 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null
        mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
    fi
}

set_state() {
    echo "$2" > "$STATE_ROOT/$1" 2>/dev/null
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid" 2>/dev/null
        return 0
    fi
    local pid
    pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$pid" ] && [ ! -d "/proc/$pid" ]; then
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" 2>/dev/null && { echo $$ > "$LOCK_DIR/pid" 2>/dev/null; return 0; }
    fi
    return 1
}

release_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null
}

# config.json -> pkg<TAB>enabled<TAB>name<TAB>dir
# 行格式来自 JS 侧 JSON.stringify(config, null, 2)
parse_config() {
    awk '
    function emit() {
        if (pkg != "") {
            if (nm == "") nm = pkg
            for (i=1; i<=dcount; i++) print pkg "\t" en "\t" nm "\t" dirs[i]
            if (dcount == 0) print pkg "\t" en "\t" nm "\t"
        }
    }
    {
        line = $0
        if (match(line, /^    "[^"]+": \{$/)) {
            emit()
            pkg = line
            gsub(/^    "/, "", pkg); gsub(/": \{$/, "", pkg)
            en = "false"; nm = ""; dcount = 0; indirs = 0
        }
        else if (pkg != "") {
            if (match(line, /"enabled": (true|false)/)) {
                en = (index(line, "true") > 0) ? "true" : "false"
            }
            else if (match(line, /"name": "[^"]*"/)) {
                nm = line
                gsub(/^.*"name": "/, "", nm); gsub(/",?$/, "", nm)
            }
            else if (index(line, "\"dirs\"") > 0) { indirs = 1 }
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

wait_for_boot() {
    local count=0
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        sleep 1
        count=$((count + 1))
        [ $count -ge 120 ] && { log "boot 等待超时"; return 1; }
    done
    return 0
}

wait_for_data() {
    local count=0 n
    while [ $count -lt 90 ]; do
        n=$(ls /data/data 2>/dev/null | wc -l)
        if [ -d /data/data/com.android.settings ] && [ "$n" -gt 20 ]; then
            log "数据目录就绪 ($n 项)"
            return 0
        fi
        sleep 2
        count=$((count + 1))
    done
    log "数据目录超时"
    return 1
}

# mv 原目录到 backup，原位放 chmod 000 占坑防重新下载
backup_item() {
    local pkg="$1" rel="$2"
    local src="/data/data/$pkg/$rel"
    local dst="$BACKUP_ROOT/$pkg/$rel"

    [ -e "$src" ] || return 2
    [ -e "$dst" ] && return 2

    mkdir -p "$(dirname "$dst")"
    mv "$src" "$dst" 2>/dev/null || { log "    移除失败 $rel"; return 1; }
    if [ -d "$dst" ]; then
        touch "$src" && chmod 000 "$src" 2>/dev/null
    else
        mkdir -p "$src" && chmod 000 "$src" 2>/dev/null
    fi
    grep -Fx -- "$rel" "$BACKUP_ROOT/$pkg/$RESTORE_LIST" >/dev/null 2>&1 || echo "$rel" >> "$BACKUP_ROOT/$pkg/$RESTORE_LIST"
    return 0
}

restore_item() {
    local pkg="$1" rel="$2"
    local src="$BACKUP_ROOT/$pkg/$rel"
    local dst="/data/data/$pkg/$rel"

    [ -e "$src" ] || return 2

    if [ -e "$dst" ]; then
        chmod 755 "$dst" 2>/dev/null
        rm -rf "$dst" 2>/dev/null
    fi
    [ -e "$dst" ] && return 2

    mkdir -p "$(dirname "$dst")"
    mv "$src" "$dst" 2>/dev/null || { log "    恢复失败 $rel"; return 1; }

    local appu ctx
    appu=$(stat -c "%U:%G" "/data/data/$pkg" 2>/dev/null)
    ctx=$(ls -Zd "/data/data/$pkg" 2>/dev/null | awk '{print $1}')
    [ -n "$appu" ] && chown -R "$appu" "$dst" 2>/dev/null
    [ -n "$ctx" ] && chcon -R "$ctx" "$dst" 2>/dev/null
    return 0
}

process_app() {
    local pkg="$1" name="$2" enabled="$3"
    shift 3
    local ok=0 fail=0 skip=0 rel

    if [ ! -d "/data/data/$pkg" ]; then
        log "$name: 未安装"
        return 0
    fi

    for rel in "$@"; do
        [ -z "$rel" ] && continue
        if [ "$enabled" = "true" ]; then
            backup_item "$pkg" "$rel"
        else
            restore_item "$pkg" "$rel"
        fi
        case $? in
            0) ok=$((ok + 1)) ;;
            1) fail=$((fail + 1)) ;;
            *) skip=$((skip + 1)) ;;
        esac
    done

    if [ "$enabled" = "false" ]; then
        rm -rf "$BACKUP_ROOT/$pkg" 2>/dev/null
    fi

    set_state "$pkg" "$([ "$enabled" = "true" ] && echo active || echo inactive)"

    local mode
    [ "$enabled" = "true" ] && mode="系统内核" || mode="自带内核"
    if [ $ok -eq 0 ] && [ $fail -eq 0 ]; then
        log "$name: $mode 无变化"
    else
        log "$name: $mode 处理 $ok 项 失败 $fail 项"
    fi
}

run() {
    parse_config | awk -F'\t' '
        { if (!($1 in seen)) { order[++n]=$1; seen[$1]; en[$1]=$2; nm[$1]=$3 }
          if ($4 != "") d[$1] = d[$1] " " $4 }
        END { for (i=1; i<=n; i++) print order[i] "\t" en[order[i]] "\t" nm[order[i]] "\t" d[order[i]] }
    ' | while IFS="$TAB" read -r pkg en nm dirs; do
        [ -z "$pkg" ] && continue
        process_app "$pkg" "$nm" "$en" $dirs
    done
}

main() {
    if [ -z "$FSW_IN_NS" ] && [ -e /proc/1/ns/mnt ]; then
        if [ "$(readlink /proc/$$/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]; then
            if command -v nsenter >/dev/null 2>&1; then
                FSW_IN_NS=1 FSW_MODE="$FSW_MODE" exec nsenter --mount=/proc/1/ns/mnt -- /system/bin/sh "$0"
            fi
        fi
    fi

    mkdir -p "$BACKUP_ROOT" "$STATE_ROOT" "$(dirname "$LOG_FILE")"
    [ -f "$CONFIG_FILE" ] || { log "配置文件缺失，退出"; exit 1; }

    rotate_log
    VER=$(grep "^version=" "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
    [ -n "$VER" ] || VER="未知版本"
    log "--- Force System WebView $VER (mode=$FSW_MODE) ---"

    if [ "$FSW_MODE" = "normal" ]; then
        wait_for_boot
        sleep 5
        wait_for_data
    fi

    if ! acquire_lock; then
        log "另一实例持有锁，退出"
        exit 0
    fi

    run

    release_lock
    rm -f "$DATA_ROOT/.migrated_v2"

    cp -f "$CONFIG_FILE" "$MODDIR/webroot/config.json" 2>/dev/null
    chmod 644 "$MODDIR/webroot/config.json" 2>/dev/null
    log "--- 执行完成 ---"
}

main
