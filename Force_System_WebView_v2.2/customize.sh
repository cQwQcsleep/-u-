# Force System WebView installer customization
ui_print '- Installing Force System WebView'
ui_print '- Compatible with Magisk / KernelSU module managers'
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/apply_only.sh" 0 0 0755
set_perm "$MODPATH/scan.sh" 0 0 0755
set_perm "$MODPATH/status.sh" 0 0 0755
set_perm "$MODPATH/list_backups.sh" 0 0 0755
