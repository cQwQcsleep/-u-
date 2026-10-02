#!/system/bin/sh

# WebUI 手动触发，跳过等待直接应用

MODDIR="${0%/*}"
FSW_MODE="${1:-apply}" exec /system/bin/sh "$MODDIR/service.sh"
