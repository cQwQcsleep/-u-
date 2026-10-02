#!/system/bin/sh
# scan.sh — 扫描 /data/data 特征目录和备份区
# 用法: scan.sh [full|light]
#   full （默认）完整分析：输出 pkg|内核|mstat|特征目录|game|备份MB|可疑目录|新增目录，末尾 DONE|未管理数|已管理数
#   light     轻量扫描：只识别本机可管控应用（白名单 ∪ 目录模板），供应用页列表使用
# 特征目录 = 白名单正则命中 ∪ 目录模板中本机实际存在的目录

BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=busybox
MODROOTDIR=/data/adb/modules/force_system_webview
WEBROOT=$MODROOTDIR/webroot
SCAN_MODE="${1:-full}"
case "$SCAN_MODE" in
    light) OUT=$WEBROOT/scan-light.txt ;;
    *) SCAN_MODE=full; OUT=$WEBROOT/scan-result.txt ;;
esac
TPL_FILE=$WEBROOT/templates.json
CONFIG=/data/adb/force_webview/config.json
MODROOT=/data/adb/force_webview/backup
TMP=/data/adb/force_webview/.scan-cfg
PKGS=/data/adb/force_webview/.scan-pkgs
IGN=/data/adb/force_webview/.scan-ign
TPL_TMP=/data/adb/force_webview/.scan-tpl
IGN_LIST=""
TPL_PKGS=""
TPL_DATA=""
TAB=$(printf '\t')

if [ -z "$WVA_IN_NS" ] && [ -e /proc/1/ns/mnt ]; then
    if [ "$(readlink /proc/$$/ns/mnt 2>/dev/null)" != "$(readlink /proc/1/ns/mnt)" ]; then
        command -v nsenter >/dev/null 2>&1 && WVA_IN_NS=1 exec nsenter --mount=/proc/1/ns/mnt -- /system/bin/sh "$0" "$SCAN_MODE"
    fi
fi

LOCK=/data/adb/force_webview/.scan-lock
if [ -d "$LOCK" ]; then
    oldpid=$(cat "$LOCK/pid" 2>/dev/null)
    [ -n "$oldpid" ] && [ ! -d "/proc/$oldpid" ] && rm -rf "$LOCK"
fi
if ! mkdir "$LOCK" 2>/dev/null; then
    # 有实例在跑：往 OUT 写 BUSY 标记，前端可识别
    echo "BUSY|$(date +%s)" >> "$OUT"
    exit 1
fi
echo $$ > "$LOCK/pid"
trap 'rm -f "$PKGS" "$IGN" "$TPL_TMP" 2>/dev/null; rm -rf "$LOCK" 2>/dev/null' EXIT

# config -> pkg<TAB>enabled<TAB>name<TAB>dirs
[ -f "$CONFIG" ] && awk '
    function emit() {
        if (pkg != "") printf "%s\t%s\t%s\t%s\n", pkg, en, nm, dirs
    }
    {
        line = $0
        if (match(line, /^    "[^"]+": \{$/)) {
            emit()
            pkg = line
            gsub(/^    "/, "", pkg); gsub(/": \{$/, "", pkg)
            en = "false"; nm = pkg; dirs = ""; indirs = 0
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
                dirs = dirs (dirs==""?"":" ") d
            }
            else if (line ~ /^[ ]*\]/) { indirs = 0 }
        }
    }
    END { emit() }
' "$CONFIG" > "$TMP" 2>/dev/null || : > "$TMP"

# config ignored 数组 -> 忽略列表（这些应用不再出现在分析结果中）
: > "$IGN"
[ -f "$CONFIG" ] && awk '
    /^  "ignored": \[/ { ing = 1; next }
    ing && /^[ ]*\]/ { ing = 0; next }
    ing {
        s = $0
        gsub(/^[ ]*"/, "", s); gsub(/",?[ ]*$/, "", s)
        if (s != "") print s
    }
' "$CONFIG" >> "$IGN" 2>/dev/null
[ -s "$IGN" ] && IGN_LIST=$(tr '\n' ' ' < "$IGN")

# templates.json（目录模板）-> pkg<TAB>dirs
: > "$TPL_TMP"
[ -f "$TPL_FILE" ] && awk '
    /^  "[^"]+": \[/ {
        line = $0
        match(line, /^  "[^"]+"/)
        pkg = substr(line, 4, RLENGTH - 4)
        b = index(line, "["); e = index(line, "]")
        if (pkg == "" || b == 0 || e <= b) next
        items = substr(line, b + 1, e - b - 1)
        gsub(/"/, "", items)
        gsub(/, */, " ", items)
        gsub(/^ +| +$/, "", items)
        printf "%s\t%s\n", pkg, items
    }
' "$TPL_FILE" > "$TPL_TMP" 2>/dev/null
[ -s "$TPL_TMP" ] && TPL_PKGS=$(awk -F'\t' '{print $1}' "$TPL_TMP" | tr '\n' ' ')
[ -s "$TPL_TMP" ] && TPL_DATA=$(cat "$TPL_TMP")

check_features() {
    local d="$1"
    local hits=""
    for sub in $(ls "$d" 2>/dev/null | grep -E '^app_(tbs|u4|x5|xwalk|xweb|meco|r1_webview|webview_mt|h5|webview_d6|extracted_dongCore)'); do
        hits="$hits $sub"
    done
    if [ -d "$d/files" ]; then
        for sub in $(ls "$d/files" 2>/dev/null | grep -E '^(DongCore|WebViewDownloadPlugin|webview_bytedance|mtplatform|mywebview_sdk|myweb_extract|nebulaInstallApps)'); do
            hits="$hits files/$sub"
        done
    fi
    echo "$hits"
}

# 完整内核/组件残留，只对未管理应用做 du
check_kernel() {
    local d="$1"
    local hits="$2"
    for h in $hits; do
        if [ -d "$d/$h" ] && [ -n "$(du -m -d 2 "$d/$h" 2>/dev/null | $BB awk '$1 >= 50 {print; exit}')" ]; then
            echo "完整内核"
            return
        fi
    done
    echo "组件残留"
}

is_game() {
    case "$1" in
        *tmgp*|*mihoyo*|*MiHoYo*|*hypergryph*|*kurogame*|*yostar*|*YoStar*|*yo-star*|\
        *garena*|*gameloft*|*epicgames*|*riotgames*|*krafton*|*blizzard*|\
        *.game|*.games|*gamecenter*|*mobilelegends*)
            echo "game";;
        *) echo "";;
    esac
}

# 目录是否在已知列表（空格分隔）中
dir_known() {
    local rel="$1" list="$2" it
    for it in $list; do
        [ "$it" = "$rel" ] && return 0
    done
    return 1
}

# 取某包在目录模板中的目录（纯 shell，避免每包一次子进程）
tpl_dirs() {
    local want="$1" line p
    [ -z "$TPL_DATA" ] && return
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        p=${line%%"$TAB"*}
        if [ "$p" = "$want" ]; then
            echo "${line#*"$TAB"}"
            return
        fi
    done <<EOF
$TPL_DATA
EOF
}

# 特征目录 = 白名单命中 ∪ 目录模板中本机实际存在的目录
collect_dirs() {
    local d="$1" pkg="$2" out="" h tpl
    out=$(check_features "$d")
    case " $TPL_PKGS " in
        *" $pkg "*) tpl=$(tpl_dirs "$pkg") ;;
        *) tpl="" ;;
    esac
    for h in $tpl; do
        dir_known "$h" "$out" && continue
        [ -e "$d/$h" ] && out="$out $h"
    done
    echo "$out"
}

# 命中目录里不在已知列表中的部分（新增目录）
diff_dirs() {
    local hits="$1" known="$2" out="" h
    for h in $hits; do
        dir_known "$h" "$known" || out="$out $h"
    done
    echo "$out"
}

# 启发式兜底：名称含网页内核关键词，或 app_ 前缀且体积 ≥50MB 的目录
# 排除标准 WebView 数据目录（app_webview / app_webview_<包名>）
check_suspicious() {
    local d="$1" pkg="$2" known="$3"
    local out="" sub rel sz
    for sub in $(ls "$d" 2>/dev/null); do
        case "$sub" in
            app_webview|app_webview_"$pkg") continue ;;
        esac
        dir_known "$sub" "$known" && continue
        if echo "$sub" | grep -Eiq 'webview|tbs|xwalk|meco|dongcore|(^|[^a-z0-9])x5([^a-z0-9]|$)|(^|[^a-z0-9])h5([^a-z0-9]|$)'; then
            out="$out $sub"
        elif [ -d "$d/$sub" ]; then
            case "$sub" in
                app_*)
                    sz=$(du -sm "$d/$sub" 2>/dev/null | cut -f1)
                    case "$sz" in
                        ''|*[!0-9]*) sz=0 ;;
                    esac
                    [ "$sz" -ge 50 ] && out="$out $sub"
                    ;;
            esac
        fi
    done
    if [ -d "$d/files" ]; then
        for sub in $(ls "$d/files" 2>/dev/null); do
            rel="files/$sub"
            dir_known "$rel" "$known" && continue
            if echo "$sub" | grep -Eiq 'webview|tbs|xwalk|meco|dongcore|(^|[^a-z0-9])x5([^a-z0-9]|$)|(^|[^a-z0-9])h5([^a-z0-9]|$)'; then
                out="$out $rel"
            fi
        done
    fi
    echo "$out"
}


: > "$OUT"
echo "STARTED|$$|$(date +%s)" >> "$OUT"
pm list packages -3 2>/dev/null | sed "s/^package://" > "$PKGS"

total=$(grep -c . "$PKGS" 2>/dev/null)
[ -n "$total" ] || total=0
done_count=0
[ "$SCAN_MODE" = "full" ] && echo "PROGRESS|0|$total" >> "$OUT"
u=0; m=0

while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    done_count=$((done_count+1))
    [ "$SCAN_MODE" = "full" ] && echo "PROGRESS|$done_count|$total" >> "$OUT"
    d="/data/data/$pkg"
    [ -d "$d" ] || continue


    [ -n "$(ls -A "$MODROOT/$pkg" 2>/dev/null)" ] && continue

    hits=$(collect_dirs "$d" "$pkg")
    [ -z "$hits" ] && continue

    gtag=$(is_game "$pkg")
    ignored=0
    case " $IGN_LIST " in *" $pkg "*) ignored=1;; esac

    if [ "$SCAN_MODE" = "light" ]; then
        # 轻量模式只输出「尚未加入管控」的可管控应用，已配置的由前端用配置渲染
        [ "$ignored" = "1" ] && continue
        awk -F'\t' -v p="$pkg" '$1==p{found=1} END{exit !found}' "$TMP" 2>/dev/null && continue
        u=$((u+1))
        echo "$pkg||未管理|$hits|$gtag|0||" >> "$OUT"
        continue
    fi

    cfgdirs=$(awk -F'\t' -v p="$pkg" '$1==p{print $4; found=1} END{if(!found) print "<<NA>>"}' "$TMP" 2>/dev/null)

    if [ "$cfgdirs" != "<<NA>>" ]; then
        m=$((m+1))
        # 已配置应用：只提示 config 之外的新增目录；被忽略的应用不再提示
        nd=""
        if [ "$ignored" = "0" ]; then
            nd=$(diff_dirs "$hits" "$cfgdirs")
        fi
        echo "$pkg|未管控|已配置|$hits|$gtag|0||$nd" >> "$OUT"
    else
        [ "$ignored" = "1" ] && continue
        u=$((u+1))
        kernel=$(check_kernel "$d" "$hits")
        susp=$(check_suspicious "$d" "$pkg" "$hits")
        echo "$pkg|$kernel|未管理|$hits|$gtag|0|$susp|" >> "$OUT"
    fi
done < "$PKGS"

if [ "$SCAN_MODE" = "full" ]; then
    for pkg in $(ls "$MODROOT" 2>/dev/null); do
        [ -d "$MODROOT/$pkg" ] || continue
        dirs=$(awk -F'\t' -v p="$pkg" '$1==p{print $4; exit}' "$TMP" 2>/dev/null)
        [ -z "$dirs" ] && dirs=$(ls "$MODROOT/$pkg" 2>/dev/null | tr '\n' ' ')
        bk=$(du -sm "$MODROOT/$pkg" 2>/dev/null | cut -f1)
        [ -z "$bk" ] && bk=0
        gtag=$(is_game "$pkg")
        nd=""
        ignored=0
        case " $IGN_LIST " in *" $pkg "*) ignored=1;; esac
        if [ "$ignored" = "0" ] && [ -d "/data/data/$pkg" ]; then
            h=$(collect_dirs "/data/data/$pkg" "$pkg")
            [ -n "$h" ] && nd=$(diff_dirs "$h" "$dirs")
        fi
        m=$((m+1))
        echo "$pkg|管控中|已生效|$dirs|$gtag|$bk||$nd" >> "$OUT"
    done

    rm -f "$TMP"
    echo "DONE|$u|$m" >> "$OUT"
fi
