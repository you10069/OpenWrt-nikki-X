#!/bin/sh

. /lib/functions.sh
. /etc/nikki/scripts/include.sh

prepare_files
config_load nikki
config_get_bool enabled config enabled 0
config_get_bool core_only config core_only 0
config_get_bool proxy_enabled proxy enabled 0

# firewall3 executes script includes whenever its rules are rebuilt. Reapply
# Nikki only when the service has completed profile generation and is active.
if [ "$enabled" -eq 1 ] && [ "$core_only" -eq 0 ] && [ "$proxy_enabled" -eq 1 ] && \
   [ -f "$STARTED_FLAG_PATH" ] && [ -s "$RUN_PROFILE_PATH" ]; then
	"$FIREWALL_FW3_SH" apply
fi

exit 0
