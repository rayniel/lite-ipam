#!/bin/sh

# OpenWrt dnsmasq sources USER_DHCPSCRIPT from /usr/lib/dnsmasq/dhcp-script.sh
# before forwarding events into hotplug. This file must therefore be source-safe
# and must not call exit, otherwise it will terminate the wrapper early.

case "$1" in
	add|old|del|arp-add|arp-del|tftp) ;;
	*) return 0 2>/dev/null || exit 0 ;;
esac

return 0 2>/dev/null || exit 0