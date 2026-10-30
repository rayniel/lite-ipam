#!/bin/sh

. /lib/functions.sh

APP_NAME="lite-ipam"
UCI_PACKAGE="lite-ipam"
SCHEMA_PATH="/usr/libexec/lite-ipam/schema-v1.sql"
DNSMASQ_UCI_PACKAGE="dhcp"
DNSMASQ_MAIN_SECTION="@dnsmasq[0]"
DNSMASQ_LEASE_HOOK="/usr/libexec/lite-ipam/dnsmasq-lease-hook.sh"
HOTPLUG_DHCP_HOOK="/etc/hotplug.d/dhcp/90-lite-ipam"

sqlite3() {
	local error_file input_file result detail remaining="$#" argument db_seen=0 has_sql=0
	error_file="$(mktemp "${TMPDIR:-/tmp}/lite-ipam-sql.XXXXXX")" || return 1
	input_file="$error_file.input"
	: > "$input_file" || { rm -f "$error_file"; return 1; }
	while [ "$remaining" -gt 0 ]; do
		argument="$1"; shift; remaining=$((remaining - 1))
		if [ "$db_seen" -eq 1 ]; then
			printf '%s\n' "$argument" >> "$input_file"
			has_sql=1
		else
			set -- "$@" "$argument"
			[ "$argument" != "$LITE_IPAM_DB_PATH" ] || db_seen=1
		fi
	done
	[ "$has_sql" -eq 1 ] || cat > "$input_file"
	# SQLite 3.53 can continue past a failed statement on the same input line.
	# Separate statements outside quoted strings/comments and use stdin bailout.
	{
		printf 'PRAGMA foreign_keys = ON;\n'
		split_sql_statements < "$input_file"
	} | command sqlite3 -init /dev/null -list -noheader -batch -bail -cmd '.timeout 5000' "$@" 2>"$error_file"
	result=$?
	if [ "$result" -ne 0 ]; then
		detail="$(cat "$error_file")"
		log_error "sqlite exit=$result: $detail"
		record_database_failure "$result" "$detail"
	fi
	rm -f "$error_file" "$input_file"
	return "$result"
}

split_sql_statements() {
	awk '
	{
		for (i=1; i<=length($0); i++) {
			c=substr($0,i,1); n=substr($0,i+1,1)
			if (comment) {
				printf "%s",c
				if (c=="*" && n=="/") { printf "/"; i++; comment=0 }
			} else if (quote!="") {
				printf "%s",c
				if (c==quote) quote=""
			} else if (c=="-" && n=="-") {
				printf "%s",substr($0,i); break
			} else if (c=="/" && n=="*") {
				printf "/*"; i++; comment=1
			} else if (c=="\047" || c=="\"" || c=="`" || c=="[") {
				quote=(c=="[" ? "]" : c); printf "%s",c
			} else {
				printf "%s",c
				if (c==";") printf "\n"
			}
		}
		printf "\n"
	}'
}

runtime_lock_root() {
	local lock_root checksum
	command -v flock >/dev/null 2>&1 || {
		log_error "flock command is unavailable"
		return 1
	}
	checksum="$(printf '%s' "$lite_ipam_data_root" | sha256sum)" || return 1
	lock_root="/var/lock/lite-ipam-${checksum%% *}"
	mkdir -p "$lock_root" || return 1
	printf '%s' "$lock_root"
}

with_runtime_lock() (
	local name="$1"
	shift
	local lock_root
	lock_root="$(runtime_lock_root)" || return 1
	exec 9>"$lock_root/$name.lock"
	flock -x -w 15 9 || {
		log_error "timed out acquiring $name lock"
		write_status_json "$name" false "timed out acquiring runtime lock"
		return 1
	}
	"$@"
)

file_checksum() {
	local checksum
	checksum="$(sha256sum < "$1")" || return 1
	printf '%s' "${checksum%% *}"
}

record_database_failure() {
	[ -n "$lite_ipam_data_root" ] || return 0
	with_runtime_lock database record_database_failure_locked "$@"
}

record_database_failure_locked() {
	local count_file count=0
	derive_paths
	ensure_directory "$LITE_IPAM_STATUS_DIR" || return 1
	count_file="$LITE_IPAM_STATUS_DIR/database.failures"
	[ ! -f "$count_file" ] || read -r count < "$count_file"
	is_uint "$count" || count=0
	count=$((count + 1))
	printf '%s\n' "$count" > "$count_file"
	write_status_json database false "sqlite operation failed" "\"failures\": $count, \"exit_code\": $1, \"detail\": \"$(json_escape "$2")\""
}

list_dnsmasq_sections() {
	uci show "$DNSMASQ_UCI_PACKAGE" 2>/dev/null | sed -n "s/^${DNSMASQ_UCI_PACKAGE}\.\([^.=]*\)=dnsmasq$/\1/p"
}

first_dnsmasq_section() {
	list_dnsmasq_sections | sed -n '1p'
}

append_unique_word() {
	local list="$1" word="$2"
	[ -n "$word" ] || {
		printf '%s' "$list"
		return 0
	}
	case " $list " in
		*" $word "*) printf '%s' "$list" ;;
		*) printf '%s%s%s' "$list" "${list:+ }" "$word" ;;
	esac
}

list_target_dnsmasq_sections() {
	local selected default_section dhcp_sections dhcp_section iface instance result=""
	selected="$(uci_typed_get sync subnet_interfaces "")"
	default_section="$(first_dnsmasq_section)"
	[ -n "$default_section" ] || return 0
	if [ -z "$selected" ]; then
		printf '%s' "$default_section"
		return 0
	fi
	config_load dhcp
	dhcp_sections="$(uci -q show dhcp | sed -n 's/^dhcp\.\([^.=]*\)=dhcp$/\1/p')"
	for dhcp_section in $dhcp_sections; do
		config_get iface "$dhcp_section" interface
		[ -n "$iface" ] || continue
		case " $selected " in
			*" $iface "*) ;;
			*) continue ;;
		esac
		config_get instance "$dhcp_section" instance
		[ -n "$instance" ] || instance="$default_section"
		result="$(append_unique_word "$result" "$instance")"
	done
	if [ -n "$result" ]; then
		printf '%s' "$result"
	else
		printf '%s' "$default_section"
	fi
}

dnsmasq_option_matches_target_sections() {
	local option_name="$1" expected_value="$2" section_name current_value found=0
	for section_name in $(list_target_dnsmasq_sections); do
		found=1
		current_value="$(uci -q get ${DNSMASQ_UCI_PACKAGE}.${section_name}.${option_name} 2>/dev/null)"
		[ "$current_value" = "$expected_value" ] || return 1
	done
	[ "$found" = "1" ]
}

set_dnsmasq_option_target_sections() {
	local option_name="$1" option_value="$2" log_label="$3" section_name current_value changed=0 found=0 targets

	command -v uci >/dev/null 2>&1 || {
		log_error "uci command is unavailable"
		return 1
	}

	targets="$(list_target_dnsmasq_sections)"
	for section_name in $targets; do
		found=1
		current_value="$(uci -q get ${DNSMASQ_UCI_PACKAGE}.${section_name}.${option_name} 2>/dev/null)"
		[ "$current_value" = "$option_value" ] && continue
		uci -q set ${DNSMASQ_UCI_PACKAGE}.${section_name}.${option_name}="$option_value" || {
			log_error "failed to set dnsmasq ${option_name} for section ${section_name}"
			return 1
		}
		changed=1
	done

	[ "$found" = "1" ] || {
		log_error "no target dnsmasq sections found"
		return 1
	}

	[ "$changed" = "1" ] || return 0

	uci -q commit "$DNSMASQ_UCI_PACKAGE" || {
		log_error "failed to commit dnsmasq ${option_name}"
		return 1
	}

	log_info "configured dnsmasq ${log_label}: $option_value (targets: $targets)"
	return 0
}

runtime_log_path() {
	local data_root
	data_root="$(uci -q get ${UCI_PACKAGE}.@core[0].data_root 2>/dev/null)"
	[ -n "$data_root" ] || return 1
	printf '%s/logs/runtime.log' "$data_root"
}

append_runtime_log() {
	local level="$1"
	local message="$2"
	local log_path log_dir timestamp
	log_path="$(runtime_log_path)" || return 0
	log_dir="$(dirname "$log_path")"
	mkdir -p "$log_dir" || {
		logger -p daemon.err -t "$APP_NAME" "cannot create runtime log directory: $log_dir"
		return 1
	}
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf '%s [%s] %s\n' "$timestamp" "$level" "$message" >> "$log_path" || {
		logger -p daemon.err -t "$APP_NAME" "cannot append runtime log: $log_path"
		return 1
	}
}

append_system_log() {
	local level="$1"
	local message="$2"
	logger -t "$APP_NAME" "[$level] $message" 2>/dev/null || true
}

log_info() {
	append_runtime_log "INFO" "$*"
	append_system_log "INFO" "$*"
}

log_error() {
	append_runtime_log "ERROR" "$*"
	append_system_log "ERROR" "$*"
}

uci_typed_get() {
	local type_name="$1"
	local option_name="$2"
	local default_value="$3"
	local value
	value="$(uci -q get ${UCI_PACKAGE}.@${type_name}[0].${option_name})"
	if [ -n "$value" ]; then
		printf '%s' "$value"
	else
		printf '%s' "$default_value"
	fi
}

load_core_config() {
	command -v uci >/dev/null 2>&1 || return 1
	lite_ipam_enabled="$(uci_typed_get core enabled 1)"
	lite_ipam_node_name="$(uci_typed_get core node_name "")"
	lite_ipam_data_root="$(uci_typed_get core data_root "")"
	lite_ipam_auto_init="$(uci_typed_get core auto_init 1)"
	lite_ipam_auto_create_subdirs="$(uci_typed_get core auto_create_subdirs 1)"
	lite_ipam_apply_mode="$(uci_typed_get core apply_mode immediate)"
	lite_ipam_backup_enabled="$(uci_typed_get backup enabled 1)"
	lite_ipam_backup_retention_days="$(uci_typed_get core backup_retention_days 30)"
	lite_ipam_backup_cron_enabled="$(uci_typed_get backup cron_enabled 1)"
	lite_ipam_backup_cron_schedule="$(uci_typed_get backup cron_schedule '0 3 * * *')"
	lite_ipam_backup_mail_enabled="$(uci_typed_get backup mail_enabled 0)"
	lite_ipam_backup_mail_from="$(uci_typed_get backup mail_from '')"
	lite_ipam_backup_mail_to="$(uci_typed_get backup mail_to '')"
	lite_ipam_backup_smtp_host="$(uci_typed_get backup smtp_host '')"
	lite_ipam_backup_smtp_port="$(uci_typed_get backup smtp_port 587)"
	lite_ipam_backup_smtp_user="$(uci_typed_get backup smtp_user '')"
	lite_ipam_backup_smtp_password="$(uci_typed_get backup smtp_password '')"
	lite_ipam_backup_smtp_tls="$(uci_typed_get backup smtp_tls 1)"

	[ -n "$lite_ipam_node_name" ] || lite_ipam_node_name="$(uname -n 2>/dev/null)"
	case "$lite_ipam_apply_mode" in
		immediate) ;;
		*)
			log_info "unsupported apply_mode '$lite_ipam_apply_mode', forcing immediate"
			lite_ipam_apply_mode="immediate"
		;;
	esac
}

load_api_config() {
	command -v uci >/dev/null 2>&1 || return 1
	lite_ipam_api_enabled="$(uci_typed_get api enabled 1)"
	lite_ipam_api_read_token="$(uci_typed_get api read_token '')"
	lite_ipam_api_require_token="$(uci_typed_get api require_token 0)"
}

load_maintenance_config() {
	command -v uci >/dev/null 2>&1 || return 1
	lite_ipam_maintenance_enabled="$(uci_typed_get maintenance enabled 1)"
	lite_ipam_lease_retention_days="$(uci_typed_get maintenance lease_retention_days 90)"
	lite_ipam_event_retention_days="$(uci_typed_get maintenance event_retention_days 180)"
	lite_ipam_vacuum_after_cleanup="$(uci_typed_get maintenance vacuum_after_cleanup 1)"
	case "$lite_ipam_lease_retention_days" in
		*[!0-9]*|"") lite_ipam_lease_retention_days=90 ;;
	esac
	case "$lite_ipam_event_retention_days" in
		*[!0-9]*|"") lite_ipam_event_retention_days=180 ;;
	esac
}

is_enabled() {
	[ "$lite_ipam_enabled" = "1" ] || [ "$lite_ipam_enabled" = "true" ]
}

is_dangerous_root() {
	case "$1" in
		""|/|/etc|/tmp|/var|/root)
			return 0
		;;
		*)
			return 1
		;;
	esac
}

validate_data_root() {
	local data_root="$1"
	local parent_dir

	[ -n "$data_root" ] || {
		log_error "data_root is empty"
		return 1
	}

	case "$data_root" in
		/*) ;;
		*)
			log_error "data_root must be an absolute path: $data_root"
			return 1
		;;
	esac

	is_dangerous_root "$data_root" && {
		log_error "data_root is not allowed: $data_root"
		return 1
	}
	case "$data_root" in
		/mnt/*|/media/*)
			if [ "$(uci_typed_get health strict_storage_check 1)" = "1" ] \
				&& ! awk -v path="$data_root" '$2 != "/" && (path == $2 || index(path, $2 "/") == 1) { found=1 } END { exit !found }' /proc/mounts; then
				log_error "data_root storage is not mounted: $data_root"
				return 1
			fi
			;;
	esac

	parent_dir="$(dirname "$data_root")"
	[ -d "$parent_dir" ] || {
		log_error "data_root parent directory does not exist: $parent_dir"
		return 1
	}

	[ -w "$parent_dir" ] || [ -d "$data_root" ] || {
		log_error "data_root parent directory is not writable: $parent_dir"
		return 1
	}

	return 0
}

ensure_directory() {
	local dir_path="$1"
	[ -d "$dir_path" ] && return 0
	mkdir -p "$dir_path" || {
		log_error "failed to create directory: $dir_path"
		return 1
	}
}

derive_paths() {
	LITE_IPAM_DB_DIR="$lite_ipam_data_root/db"
	LITE_IPAM_DB_PATH="$LITE_IPAM_DB_DIR/ipam.db"
	LITE_IPAM_DNSMASQ_DIR="$lite_ipam_data_root/dnsmasq"
	LITE_IPAM_HOSTS_DIR="$LITE_IPAM_DNSMASQ_DIR/active"
	LITE_IPAM_HOSTS_CONF_PATH="$LITE_IPAM_HOSTS_DIR/hosts.conf"
	LITE_IPAM_LAST_GOOD_PATH="$LITE_IPAM_DNSMASQ_DIR/hosts.last-good"
	LITE_IPAM_PENDING_DIR="$LITE_IPAM_DNSMASQ_DIR/pending"
	LITE_IPAM_LOGS_DIR="$lite_ipam_data_root/logs"
	LITE_IPAM_BACKUP_DIR="$lite_ipam_data_root/backup"
	LITE_IPAM_EXPORT_DIR="$lite_ipam_data_root/export"
	LITE_IPAM_TMP_DIR="$lite_ipam_data_root/tmp"
	LITE_IPAM_STATUS_DIR="$LITE_IPAM_TMP_DIR/status"
	LITE_IPAM_META_PATH="$lite_ipam_data_root/meta.json"
	LITE_IPAM_README_PATH="$lite_ipam_data_root/README.md"
}

json_escape() {
	printf '%s' "$1" | sed -e ':a' -e '$!{N;ba;}' -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r/\\r/g' -e 's/	/\\t/g' -e 's/\n/\\n/g'
}

sql_escape() {
	printf '%s' "$1" | sed "s/'/''/g"
}

current_timestamp() {
	date -u +%Y-%m-%dT%H:%M:%SZ
}

first_word() {
	local value="$1"
	set -- $value
	printf '%s' "$1"
}

normalize_bool() {
	case "$1" in
		1|true|TRUE|yes|on) printf '%s' 1 ;;
		*) printf '%s' 0 ;;
	esac
}

is_uint() {
	case "$1" in
		*[!0-9]*|"") return 1 ;;
		*) return 0 ;;
	esac
}

valid_ipv4() {
	printf '%s\n' "$1" | awk -F. '
		NF != 4 { exit 1 }
		{ for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || length($i) > 3 || $i + 0 > 255 || (length($i) > 1 && substr($i, 1, 1) == "0")) exit 1 }
	'
}

valid_mac() {
	printf '%s\n' "$1" | grep -Eq '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'
}

valid_hostname() {
	[ -z "$1" ] && return 0
	[ "${#1}" -le 253 ] || return 1
	printf '%s\n' "$1" | awk -F. '
		{ for (i = 1; i <= NF; i++) if (length($i) < 1 || length($i) > 63 || $i !~ /^[a-zA-Z0-9_]([a-zA-Z0-9_-]*[a-zA-Z0-9_])?$/) exit 1 }
	'
}

ip_to_int() {
	valid_ipv4 "$1" || return 1
	local old_ifs="$IFS"
	IFS=.
	set -- $1
	IFS="$old_ifs"
	printf '%s' $((($1 << 24) + ($2 << 16) + ($3 << 8) + $4))
}

int_to_ip() {
	local value="$1"
	printf '%s.%s.%s.%s' \
		$(((value >> 24) & 255)) \
		$(((value >> 16) & 255)) \
		$(((value >> 8) & 255)) \
		$((value & 255))
}

netmask_to_prefix() {
	case "$1" in
		255.255.255.255) printf '%s' 32 ;;
		255.255.255.254) printf '%s' 31 ;;
		255.255.255.252) printf '%s' 30 ;;
		255.255.255.248) printf '%s' 29 ;;
		255.255.255.240) printf '%s' 28 ;;
		255.255.255.224) printf '%s' 27 ;;
		255.255.255.192) printf '%s' 26 ;;
		255.255.255.128) printf '%s' 25 ;;
		255.255.255.0) printf '%s' 24 ;;
		255.255.254.0) printf '%s' 23 ;;
		255.255.252.0) printf '%s' 22 ;;
		255.255.248.0) printf '%s' 21 ;;
		255.255.240.0) printf '%s' 20 ;;
		255.255.224.0) printf '%s' 19 ;;
		255.255.192.0) printf '%s' 18 ;;
		255.255.128.0) printf '%s' 17 ;;
		255.255.0.0) printf '%s' 16 ;;
		255.254.0.0) printf '%s' 15 ;;
		255.252.0.0) printf '%s' 14 ;;
		255.248.0.0) printf '%s' 13 ;;
		255.240.0.0) printf '%s' 12 ;;
		255.224.0.0) printf '%s' 11 ;;
		255.192.0.0) printf '%s' 10 ;;
		255.128.0.0) printf '%s' 9 ;;
		255.0.0.0) printf '%s' 8 ;;
		254.0.0.0) printf '%s' 7 ;;
		252.0.0.0) printf '%s' 6 ;;
		248.0.0.0) printf '%s' 5 ;;
		240.0.0.0) printf '%s' 4 ;;
		224.0.0.0) printf '%s' 3 ;;
		192.0.0.0) printf '%s' 2 ;;
		128.0.0.0) printf '%s' 1 ;;
		0.0.0.0) printf '%s' 0 ;;
		*) return 1 ;;
	esac
}

cidr_prefix() {
	local ipaddr="$1"
	local netmask="$2"
	case "$ipaddr" in
		*/*) printf '%s' "${ipaddr#*/}" ; return 0 ;;
	esac
	netmask_to_prefix "$netmask"
}

cidr_address() {
	case "$1" in
		*/*) printf '%s' "${1%%/*}" ;;
		*) printf '%s' "$1" ;;
	esac
}

network_base_from_cidr() {
	local address="$1"
	local prefix="$2"
	local ip_int mask base
	ip_int="$(ip_to_int "$address")" || return 1
	if [ "$prefix" -eq 0 ]; then
		mask=0
	else
		mask=$((((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF)))
	fi
	base=$((ip_int & mask))
	int_to_ip "$base"
}

cidr_contains_ip() {
	local ip="$1"
	local cidr="$2"
	local address prefix base ip_int base_int mask
	address="$(cidr_address "$cidr")"
	prefix="$(cidr_prefix "$cidr" "")" || return 1
	is_uint "$prefix" || return 1
	[ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || return 1
	ip_int="$(ip_to_int "$ip")" || return 1
	base="$(network_base_from_cidr "$address" "$prefix")" || return 1
	base_int="$(ip_to_int "$base")" || return 1
	if [ "$prefix" -eq 0 ]; then
		mask=0
	else
		mask=$((((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF)))
	fi
	[ $((ip_int & mask)) -eq $((base_int & mask)) ]
}

compute_dhcp_range() {
	local cidr="$1"
	local start_offset="$2"
	local limit="$3"
	local prefix address base base_int start_int end_int
	address="$(cidr_address "$cidr")"
	prefix="$(cidr_prefix "$cidr" "")" || return 1
	is_uint "$start_offset" || return 1
	is_uint "$limit" || return 1
	[ "$limit" -gt 0 ] || return 1
	base="$(network_base_from_cidr "$address" "$prefix")" || return 1
	base_int="$(ip_to_int "$base")" || return 1
	start_int=$((base_int + start_offset))
	end_int=$((start_int + limit - 1))
	printf '%s|%s' "$(int_to_ip "$start_int")" "$(int_to_ip "$end_int")"
}

derive_vlan_id() {
	local section_name="$1"
	local device_name="$2"
	local value
	value="$(uci -q get network.${section_name}.vid)"
	if is_uint "$value"; then
		printf '%s' "$value"
		return 0
	fi
	if [ -n "$device_name" ]; then
		value="$(uci -q get network.${device_name}.vid)"
		if is_uint "$value"; then
			printf '%s' "$value"
			return 0
		fi
	fi
	value="$(printf '%s' "$device_name" | sed -n 's/.*\.\([0-9][0-9]*\)$/\1/p')"
	if is_uint "$value"; then
		printf '%s' "$value"
	else
		printf '%s' 0
	fi
}

list_buffer_append() {
	LIST_BUFFER="${LIST_BUFFER:+$LIST_BUFFER }$1"
}

config_option_or_list() {
	local section_name="$1"
	local option_name="$2"
	local value
	LIST_BUFFER=""
	config_get value "$section_name" "$option_name"
	if [ -n "$value" ]; then
		printf '%s' "$value"
		return 0
	fi
	config_list_foreach "$section_name" "$option_name" list_buffer_append
	printf '%s' "$LIST_BUFFER"
}

network_interface_ipaddr() {
	first_word "$(config_option_or_list "$1" ipaddr)"
}

network_interface_dns_pair() {
	local dns_raw dns1 dns2
	dns_raw="$(config_option_or_list "$1" dns)"
	set -- $dns_raw
	dns1="$1"
	dns2="$2"
	printf '%s|%s' "$dns1" "$dns2"
}

network_interface_device_name() {
	local device_name
	device_name="$(first_word "$(config_option_or_list "$1" device)")"
	[ -n "$device_name" ] || device_name="$(first_word "$(config_option_or_list "$1" ifname)")"
	printf '%s' "$device_name"
}

network_interface_gateway() {
	local section_name="$1"
	local address="$2"
	local gateway
	gateway="$(first_word "$(config_option_or_list "$section_name" gateway)")"
	if [ -n "$gateway" ]; then
		printf '%s' "$gateway"
	else
		printf '%s' "$address"
	fi
}

sqlite_column_exists() {
	local table_name="$1"
	local column_name="$2"
	local exists
	exists="$(sqlite3 -batch -noheader -separator '|' "$LITE_IPAM_DB_PATH" "PRAGMA busy_timeout = 5000; PRAGMA table_info($table_name);" 2>/dev/null | awk -F'|' -v col="$column_name" '$2 == col { found = 1 } END { print found ? 1 : 0 }')"
	[ "$exists" = "1" ]
}

ensure_sqlite_migrations() {
	local sqlite_output
	LITE_IPAM_MIGRATION_DETAIL=""
	sqlite_column_exists leases lease_duration || {
		sqlite3 "$LITE_IPAM_DB_PATH" "ALTER TABLE leases ADD COLUMN lease_duration INTEGER;" || return 1
	}
	sqlite_column_exists leases expiry_kind || {
		sqlite3 "$LITE_IPAM_DB_PATH" "ALTER TABLE leases ADD COLUMN expiry_kind TEXT NOT NULL DEFAULT 'unknown';" || return 1
	}
	sqlite_column_exists subnets interface_name || {
		sqlite_output="$(sqlite3 "$LITE_IPAM_DB_PATH" "PRAGMA busy_timeout = 5000; ALTER TABLE subnets ADD COLUMN interface_name TEXT;" 2>&1)"
		[ "$?" -eq 0 ] || {
			LITE_IPAM_MIGRATION_DETAIL="add subnets.interface_name${sqlite_output:+ ($sqlite_output)}"
			log_error "sqlite migration failed: $LITE_IPAM_MIGRATION_DETAIL"
			return 1
		}
	}
	sqlite_column_exists subnets display_name || {
		sqlite_output="$(sqlite3 "$LITE_IPAM_DB_PATH" "PRAGMA busy_timeout = 5000; ALTER TABLE subnets ADD COLUMN display_name TEXT;" 2>&1)"
		[ "$?" -eq 0 ] || {
			LITE_IPAM_MIGRATION_DETAIL="add subnets.display_name${sqlite_output:+ ($sqlite_output)}"
			log_error "sqlite migration failed: $LITE_IPAM_MIGRATION_DETAIL"
			return 1
		}
	}
	sqlite_column_exists subnets comment || {
		sqlite_output="$(sqlite3 "$LITE_IPAM_DB_PATH" "PRAGMA busy_timeout = 5000; ALTER TABLE subnets ADD COLUMN comment TEXT;" 2>&1)"
		[ "$?" -eq 0 ] || {
			LITE_IPAM_MIGRATION_DETAIL="add subnets.comment${sqlite_output:+ ($sqlite_output)}"
			log_error "sqlite migration failed: $LITE_IPAM_MIGRATION_DETAIL"
			return 1
		}
	}
	sqlite_column_exists subnets source || {
		sqlite_output="$(sqlite3 "$LITE_IPAM_DB_PATH" "PRAGMA busy_timeout = 5000; ALTER TABLE subnets ADD COLUMN source TEXT NOT NULL DEFAULT 'system';" 2>&1)"
		[ "$?" -eq 0 ] || {
			LITE_IPAM_MIGRATION_DETAIL="add subnets.source${sqlite_output:+ ($sqlite_output)}"
			log_error "sqlite migration failed: $LITE_IPAM_MIGRATION_DETAIL"
			return 1
		}
	}
	sqlite_column_exists subnets sync_status || {
		sqlite_output="$(sqlite3 "$LITE_IPAM_DB_PATH" "PRAGMA busy_timeout = 5000; ALTER TABLE subnets ADD COLUMN sync_status TEXT NOT NULL DEFAULT 'synced';" 2>&1)"
		[ "$?" -eq 0 ] || {
			LITE_IPAM_MIGRATION_DETAIL="add subnets.sync_status${sqlite_output:+ ($sqlite_output)}"
			log_error "sqlite migration failed: $LITE_IPAM_MIGRATION_DETAIL"
			return 1
		}
	}
	sqlite_column_exists leases subnet_id || {
		sqlite_output="$(sqlite3 "$LITE_IPAM_DB_PATH" "PRAGMA busy_timeout = 5000; ALTER TABLE leases ADD COLUMN subnet_id INTEGER;" 2>&1)"
		[ "$?" -eq 0 ] || {
			LITE_IPAM_MIGRATION_DETAIL="add leases.subnet_id${sqlite_output:+ ($sqlite_output)}"
			log_error "sqlite migration failed: $LITE_IPAM_MIGRATION_DETAIL"
			return 1
		}
	}
	sqlite_column_exists events subnet_id || {
		sqlite_output="$(sqlite3 "$LITE_IPAM_DB_PATH" "PRAGMA busy_timeout = 5000; ALTER TABLE events ADD COLUMN subnet_id INTEGER;" 2>&1)"
		[ "$?" -eq 0 ] || {
			LITE_IPAM_MIGRATION_DETAIL="add events.subnet_id${sqlite_output:+ ($sqlite_output)}"
			log_error "sqlite migration failed: $LITE_IPAM_MIGRATION_DETAIL"
			return 1
		}
	}
	sqlite_output="$(sqlite3 "$LITE_IPAM_DB_PATH" <<EOF 2>&1
PRAGMA busy_timeout = 5000;
BEGIN IMMEDIATE;
UPDATE subnets SET interface_name = NULL WHERE COALESCE(interface_name, '') = '';
DELETE FROM subnets
WHERE COALESCE(interface_name, '') <> ''
  AND id NOT IN (
    SELECT MAX(id)
    FROM subnets
    WHERE COALESCE(interface_name, '') <> ''
    GROUP BY interface_name
  );
CREATE UNIQUE INDEX IF NOT EXISTS idx_subnets_interface_name_unique ON subnets(interface_name);
CREATE INDEX IF NOT EXISTS idx_leases_subnet_id ON leases(subnet_id);
CREATE INDEX IF NOT EXISTS idx_events_subnet_id ON events(subnet_id);
UPDATE subnets
SET source = COALESCE(NULLIF(source, ''), 'system'),
    sync_status = COALESCE(NULLIF(sync_status, ''), 'synced'),
    display_name = COALESCE(NULLIF(display_name, ''), name)
WHERE source IS NULL OR source = '' OR sync_status IS NULL OR sync_status = '' OR display_name IS NULL OR display_name = '';
UPDATE hosts
SET reserved = 1,
	updated_at = COALESCE(NULLIF(updated_at, ''), strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
WHERE source = 'dhcp_observed'
	AND reservation_type = 'auto'
	AND COALESCE(reserved, 1) <> 1;
CREATE INDEX IF NOT EXISTS idx_leases_current ON leases(subnet_id, state, mac, ip);
UPDATE leases SET state='superseded'
WHERE state='active' AND id NOT IN (
 SELECT MAX(id) FROM leases WHERE state='active' GROUP BY subnet_id,mac);
UPDATE leases SET state='superseded'
WHERE state='active' AND id NOT IN (
 SELECT MAX(id) FROM leases WHERE state='active' GROUP BY subnet_id,ip);
CREATE UNIQUE INDEX IF NOT EXISTS idx_leases_active_mac ON leases(subnet_id,mac) WHERE state='active';
CREATE UNIQUE INDEX IF NOT EXISTS idx_leases_active_ip ON leases(subnet_id,ip) WHERE state='active';
PRAGMA user_version = 2;
COMMIT;
EOF
	)"
	[ "$?" -eq 0 ] || {
		LITE_IPAM_MIGRATION_DETAIL="finalize migration${sqlite_output:+ ($sqlite_output)}"
		log_error "sqlite migration failed: $LITE_IPAM_MIGRATION_DETAIL"
		return 1
	}
	LITE_IPAM_MIGRATION_DETAIL=""
}

write_status_json() {
	local name="$1"
	local ok="$2"
	local message="$3"
	local extra_json="$4"
	local path
	local signature_path
	local signature
	local previous_signature
	local timestamp

	derive_paths
	ensure_directory "$LITE_IPAM_STATUS_DIR" || return 1
	path="$LITE_IPAM_STATUS_DIR/$name.json"
	signature_path="$LITE_IPAM_STATUS_DIR/$name.sig"
	signature="$ok|$message|$extra_json"
	previous_signature="$(cat "$signature_path" 2>/dev/null)"
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	cat > "$path.$$" <<EOF
{
  "name": "$(json_escape "$name")",
  "ok": $ok,
  "message": "$(json_escape "$message")",
  "updated_at": "$timestamp"${extra_json:+,
  $extra_json}
}
EOF
	mv "$path.$$" "$path" || {
		log_error "failed to publish status: $name"
		return 1
	}
	local history_path=""
	if [ "$ok" = "false" ]; then
		history_path="$LITE_IPAM_STATUS_DIR/$name.last-failure.json"
		rm -f "$LITE_IPAM_STATUS_DIR/$name.recovery.json"
	else
		case "$previous_signature" in
			false\|*) history_path="$LITE_IPAM_STATUS_DIR/$name.recovery.json" ;;
		esac
	fi
	if [ -n "$history_path" ]; then
		cp "$path" "$history_path.$$" && mv "$history_path.$$" "$history_path" || {
			log_error "failed to preserve status history: $name"
			return 1
		}
	fi
	printf '%s' "$signature" > "$signature_path" 2>/dev/null || true
	if [ "$ok" != "true" ] || { [ "$name" != "hook" ] && [ "$previous_signature" != "$signature" ]; }; then
		append_runtime_log "STATUS" "$name: $message"
		append_system_log "STATUS" "$name: $message"
	fi
}

write_readme_if_missing() {
	[ -f "$LITE_IPAM_README_PATH" ] && return 0
	cat > "$LITE_IPAM_README_PATH" <<EOF
lite-ipam data directory

This directory stores runtime data for lite-ipam.

db/
  SQLite database files.
dnsmasq/
  Generated dnsmasq reservation files.
logs/
  Runtime logs.
backup/
  Local backup archives.
export/
  Exported snapshots.
tmp/
  Temporary working files.
EOF
}

write_meta_if_missing() {
	local node_id
	local initialized_at

	[ -f "$LITE_IPAM_META_PATH" ] && return 0

	node_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
	[ -n "$node_id" ] || node_id="$(date +%s)-$$"
	initialized_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	cat > "$LITE_IPAM_META_PATH" <<EOF
{
  "app": "lite-ipam",
  "schema_version": 1,
  "node_id": "$node_id",
  "node_name": "$lite_ipam_node_name",
  "data_root": "$lite_ipam_data_root",
  "initialized_at": "$initialized_at"
}
EOF
}

ensure_hosts_conf() {
	[ -f "$LITE_IPAM_HOSTS_CONF_PATH" ] && return 0
	: > "$LITE_IPAM_HOSTS_CONF_PATH" || {
		log_error "failed to create hosts.conf: $LITE_IPAM_HOSTS_CONF_PATH"
		return 1
	}
}

ensure_sqlite_schema() {
	local sqlite_output
	command -v sqlite3 >/dev/null 2>&1 || {
		log_error "sqlite3 command is unavailable"
		return 1
	}
	[ -f "$SCHEMA_PATH" ] || {
		log_error "schema file is missing: $SCHEMA_PATH"
		return 1
	}

	sqlite_output="$(
		(
			printf 'PRAGMA busy_timeout = 5000;\n'
			cat "$SCHEMA_PATH"
		) | sqlite3 "$LITE_IPAM_DB_PATH" 2>&1
	)"
	if [ "$?" -ne 0 ]; then
		log_error "failed to initialize sqlite schema: $LITE_IPAM_DB_PATH${sqlite_output:+ ($sqlite_output)}"
		return 1
	fi
	sqlite_output="$(printf 'PRAGMA busy_timeout = 5000;\nSELECT 1;\n' | sqlite3 "$LITE_IPAM_DB_PATH" 2>&1)"
	if [ "$?" -ne 0 ]; then
		log_error "failed to verify sqlite availability after schema init: $LITE_IPAM_DB_PATH${sqlite_output:+ ($sqlite_output)}"
		return 1
	fi
	ensure_sqlite_migrations || {
		log_error "failed to migrate sqlite schema: $LITE_IPAM_DB_PATH${LITE_IPAM_MIGRATION_DETAIL:+ ($LITE_IPAM_MIGRATION_DETAIL)}"
		write_status_json "health" false "failed to migrate sqlite schema" "\"db_path\": \"$(json_escape "$LITE_IPAM_DB_PATH")\"${LITE_IPAM_MIGRATION_DETAIL:+, \"detail\": \"$(json_escape "$LITE_IPAM_MIGRATION_DETAIL")\"}"
		return 1
	}
	return 0
}

sanitize_dnsmasq_field() {
	local value="$1"
	printf '%s' "$value" | tr '\r\n,;' '    '
}

validate_hosts_file() {
	local path="$1" config_file mac ip hostname extra output
	config_file="$LITE_IPAM_PENDING_DIR/check.$$.conf"
	: > "$config_file" || return 1
	while IFS=',' read -r mac ip hostname extra; do
		case "$mac" in ""|\#*) continue ;; esac
		if ! valid_mac "$mac" || ! valid_ipv4 "$ip" || ! valid_hostname "$hostname" || [ -n "$extra" ]; then
			rm -f "$config_file"
			log_error "invalid reservation in $path: mac=$mac ip=$ip hostname=$hostname"
			return 1
		fi
		printf 'dhcp-host=%s,%s%s\n' "$mac" "$ip" "${hostname:+,$hostname}" >> "$config_file"
	done < "$path"
	output="$(dnsmasq --test --conf-file="$config_file" 2>&1)"
	local result=$?
	rm -f "$config_file"
	[ "$result" -eq 0 ] || {
		log_error "dnsmasq reservation validation failed: $output"
		return 1
	}
}

generate_hosts_conf() {
	local pending_file
	local sqlite_output
	local mac
	local ip
	local hostname
	local line
	local entry_count

	derive_paths
	ensure_directory "$LITE_IPAM_PENDING_DIR" || return 1
	pending_file="$LITE_IPAM_PENDING_DIR/hosts.conf.$$"

	cat > "$pending_file" <<EOF
# generated by lite-ipam
# do not edit manually
EOF

	sqlite_output="$(sqlite3 -batch -noheader -separator '|' "$LITE_IPAM_DB_PATH" \
		"SELECT h.mac, h.ip, COALESCE(h.hostname, '')
		 FROM hosts h JOIN subnets s ON s.id = h.subnet_id
		 WHERE h.enabled = 1 AND h.reserved = 1 AND s.enabled = 1
		   AND s.interface_name IN ($(selected_interface_sql_list || printf \"''\"))
		 ORDER BY h.vlan_id ASC, h.ip ASC;")" || {
		rm -f "$pending_file"
		write_status_json "generation" false "failed to query hosts from sqlite"
		log_error "failed to query hosts from sqlite"
		return 1
	}

	if [ -n "$sqlite_output" ]; then
		printf '%s\n' "$sqlite_output" | while IFS='|' read -r mac ip hostname; do
			valid_mac "$mac" && valid_ipv4 "$ip" && valid_hostname "$hostname" || exit 1
			line="$mac,$ip"
			[ -n "$hostname" ] && line="$line,$hostname"
			printf '%s\n' "$line"
		done >> "$pending_file" || {
			rm -f "$pending_file"
			write_status_json "generation" false "failed to render dnsmasq hosts file"
			log_error "failed to render dnsmasq hosts file"
			return 1
		}
	fi

	validate_hosts_file "$pending_file" || {
		rm -f "$pending_file"
		write_status_json generation false "reservation validation failed; previous file retained"
		return 1
	}
	entry_count="$(printf '%s\n' "$sqlite_output" | sed '/^$/d' | wc -l | tr -d ' ')"
	if cmp -s "$pending_file" "$LITE_IPAM_HOSTS_CONF_PATH"; then
		rm -f "$pending_file"
		write_status_json generation true "dnsmasq hosts file unchanged" "\"entries\": $entry_count, \"changed\": false"
		return 0
	fi
	mv "$pending_file" "$LITE_IPAM_HOSTS_CONF_PATH" || {
		rm -f "$pending_file"
		write_status_json "generation" false "failed to replace hosts.conf atomically"
		log_error "failed to replace hosts.conf atomically"
		return 1
	}

	write_status_json "generation" true "dnsmasq hosts file generated" "\"entries\": $entry_count, \"changed\": true, \"hosts_conf_path\": \"$(json_escape "$LITE_IPAM_HOSTS_CONF_PATH")\""

	log_info "generated dnsmasq hosts file at $LITE_IPAM_HOSTS_CONF_PATH"
	return 0
}

ensure_dnsmasq_integration() {
	dnsmasq_option_matches_target_sections "dhcphostsfile" "$LITE_IPAM_HOSTS_DIR" && return 0
	set_dnsmasq_option_target_sections "dhcphostsfile" "$LITE_IPAM_HOSTS_DIR" "dhcphostsfile directory"
}

ensure_dnsmasq_lease_hook() {
	dnsmasq_option_matches_target_sections "dhcpscript" "$DNSMASQ_LEASE_HOOK" && return 0
	set_dnsmasq_option_target_sections "dhcpscript" "$DNSMASQ_LEASE_HOOK" "dhcpscript"
}

reload_dnsmasq() {
	[ -x /etc/init.d/dnsmasq ] || {
		log_error "dnsmasq init script is unavailable"
		return 1
	}

	/etc/init.d/dnsmasq reload || {
		log_error "dnsmasq reload failed"
		return 1
	}

	log_info "reloaded dnsmasq"
	return 0
}

reload_dnsmasq_deferred() {
	derive_paths
	ensure_directory "$LITE_IPAM_TMP_DIR" || return 1
	printf '%s:%s\n' "$(current_timestamp)" "$$" > "$LITE_IPAM_TMP_DIR/hosts.dirty.$$" || return 1
	mv "$LITE_IPAM_TMP_DIR/hosts.dirty.$$" "$LITE_IPAM_TMP_DIR/hosts.dirty"
}

apply_dnsmasq_hosts() {
	init_data_root || return 1
	with_runtime_lock publication publish_hosts_locked
}

publish_hosts_locked() {
	local before after token attempts=0 logs targets count required=0 dirty
	dirty="$(cat "$LITE_IPAM_TMP_DIR/hosts.dirty" 2>/dev/null)"
	before="$(file_checksum "$LITE_IPAM_HOSTS_CONF_PATH")" || return 1
	generate_hosts_conf || return 1
	after="$(file_checksum "$LITE_IPAM_HOSTS_CONF_PATH")" || return 1
	if [ "$before" = "$after" ] \
		&& dnsmasq_option_matches_target_sections dhcphostsfile "$LITE_IPAM_HOSTS_DIR" \
		&& [ -f "$LITE_IPAM_STATUS_DIR/publication.json" ] \
		&& grep -q '"ok": true' "$LITE_IPAM_STATUS_DIR/publication.json" \
		&& grep -Fq "\"checksum\": \"$after\"" "$LITE_IPAM_STATUS_DIR/publication.json"; then
		[ "$dirty" != "$(cat "$LITE_IPAM_TMP_DIR/hosts.dirty" 2>/dev/null)" ] || rm -f "$LITE_IPAM_TMP_DIR/hosts.dirty"
		return 0
	fi
	ensure_dnsmasq_integration || return 1
	ensure_dnsmasq_lease_hook || return 1
	token="ipam-publish-$$-$(date +%s)"
	logger -t "$APP_NAME" "$token" || return 1
	targets="$(list_target_dnsmasq_sections)"
	for count in $targets; do required=$((required + 1)); done
	if reload_dnsmasq; then
		while [ "$attempts" -lt 8 ]; do
			logs="$(logread | awk -v marker="$token" 'index($0, marker) { found=1; next } found')"
			count="$(printf '%s\n' "$logs" | grep -F "read $LITE_IPAM_HOSTS_CONF_PATH" | wc -l | tr -d ' ')"
			if [ "$count" -ge "$required" ] && [ "$required" -gt 0 ] \
				&& ! printf '%s\n' "$logs" | grep -F "$LITE_IPAM_HOSTS_CONF_PATH" | grep -Eq 'bad |failed|cannot|error'; then
				cp "$LITE_IPAM_HOSTS_CONF_PATH" "$LITE_IPAM_LAST_GOOD_PATH" || return 1
				mark_published_hosts || return 1
				write_status_json publication true "dnsmasq reservation load verified" "\"load_verified\": true, \"target_instances\": $required, \"checksum\": \"$(json_escape "$after")\""
				[ "$dirty" != "$(cat "$LITE_IPAM_TMP_DIR/hosts.dirty" 2>/dev/null)" ] || rm -f "$LITE_IPAM_TMP_DIR/hosts.dirty"
				return 0
			fi
			attempts=$((attempts + 1))
			sleep 1
		done
	fi
	write_status_json publication false "dnsmasq reservation load not verified" "\"load_verified\": false, \"detail\": \"$(json_escape "$logs")\""
	if [ -f "$LITE_IPAM_LAST_GOOD_PATH" ] && validate_hosts_file "$LITE_IPAM_LAST_GOOD_PATH"; then
		cp "$LITE_IPAM_LAST_GOOD_PATH" "$LITE_IPAM_PENDING_DIR/rollback.$$" \
			&& mv "$LITE_IPAM_PENDING_DIR/rollback.$$" "$LITE_IPAM_HOSTS_CONF_PATH" \
			&& reload_dnsmasq || log_error "failed to restore last known good reservations"
	fi
	return 1
}

mark_published_hosts() {
	local mac ip hostname sql_file
	sql_file="$LITE_IPAM_TMP_DIR/published.$$.sql"
	printf 'BEGIN IMMEDIATE;\n' > "$sql_file" || return 1
	while IFS=',' read -r mac ip hostname; do
		case "$mac" in ""|\#*) continue ;; esac
		printf "UPDATE hosts SET sync_status='synced' WHERE enabled=1 AND reserved=1 AND mac='%s' AND ip='%s' AND COALESCE(hostname,'')='%s';\n" \
			"$(sql_escape "$mac")" "$(sql_escape "$ip")" "$(sql_escape "$hostname")" >> "$sql_file"
	done < "$LITE_IPAM_HOSTS_CONF_PATH"
	printf 'COMMIT;\n' >> "$sql_file"
	sqlite3 "$LITE_IPAM_DB_PATH" < "$sql_file"
	local result=$?
	rm -f "$sql_file"
	return "$result"
}

apply_dnsmasq_lease_hook() {
	init_data_root || return 1
	dnsmasq_option_matches_target_sections dhcpscript "$DNSMASQ_LEASE_HOOK" && return 0
	ensure_dnsmasq_lease_hook || return 1
	reload_dnsmasq || return 1
	return 0
}

run_worker() {
	local lock_root
	prepare_runtime || return 1
	lock_root="$(runtime_lock_root)" || return 1
	exec 8>"$lock_root/worker.lock"
	flock -x -w 15 8 || {
		log_error "another lease reconciliation worker is already running"
		return 1
	}
	worker_loop
}

worker_loop() {
	local tick=0 retry_at=0 uptime_seconds
	write_status_json worker true "lease reconciliation worker running" "\"pid\": $$"
	trap 'exit 0' TERM INT
	while :; do
		if [ "$tick" -eq 0 ]; then
			run_lease_sync >/dev/null || log_error "periodic lease reconciliation failed"
			write_status_json worker true "lease reconciliation worker running" "\"pid\": $$"
			rotate_runtime_log || log_error "runtime log rotation failed"
		fi
		read -r uptime_seconds _ < /proc/uptime
		uptime_seconds="${uptime_seconds%%.*}"
		if [ -f "$LITE_IPAM_TMP_DIR/hosts.dirty" ] && [ "$uptime_seconds" -ge "$retry_at" ]; then
			sleep 2
			if ! with_runtime_lock publication publish_hosts_locked; then
				retry_at=$((uptime_seconds + 30))
				log_error "reservation publication failed; retrying after backoff"
			fi
		fi
		sleep 2
		tick=$(((tick + 2) % 60))
	done
}

rotate_runtime_log() {
	local path bytes
	path="$LITE_IPAM_LOGS_DIR/runtime.log"
	[ -f "$path" ] || return 0
	bytes="$(wc -c < "$path")"
	[ "$bytes" -le 1048576 ] || mv "$path" "$path.1"
}

should_auto_repair_dnsmasq_hook() {
	case "$1" in
		subnet-sync)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

auto_repair_dnsmasq_lease_hook() {
	local enabled hook_mismatch hostsfile_mismatch repaired

	command -v uci >/dev/null 2>&1 || return 0
	load_core_config || return 0
	enabled="$(uci -q get ${UCI_PACKAGE}.@core[0].enabled 2>/dev/null)"
	[ -n "$enabled" ] || enabled="1"
	[ "$(normalize_bool "$enabled")" = "1" ] || return 0
	[ -n "$lite_ipam_data_root" ] || return 0
	derive_paths
	ensure_directory "$LITE_IPAM_DNSMASQ_DIR" || return 1
	ensure_hosts_conf || return 1

	hook_mismatch=0
	hostsfile_mismatch=0
	repaired=0
	dnsmasq_option_matches_target_sections "dhcpscript" "$DNSMASQ_LEASE_HOOK" || hook_mismatch=1
	dnsmasq_option_matches_target_sections "dhcphostsfile" "$LITE_IPAM_HOSTS_DIR" || hostsfile_mismatch=1
	[ "$hook_mismatch" = "0" ] && [ "$hostsfile_mismatch" = "0" ] && return 0

	if [ "$hook_mismatch" = "1" ]; then
		log_error "dnsmasq dhcpscript mismatch detected on target dnsmasq sections, auto-repairing"
		ensure_dnsmasq_lease_hook || return 1
		repaired=1
	fi
	if [ "$hostsfile_mismatch" = "1" ]; then
		log_error "dnsmasq dhcphostsfile mismatch detected on target dnsmasq sections, auto-repairing"
		ensure_dnsmasq_integration || return 1
		repaired=1
	fi
	[ "$repaired" = "1" ] || return 0
	reload_dnsmasq || return 1
	if [ "$hook_mismatch" = "1" ] && [ "$hostsfile_mismatch" = "1" ]; then
		log_info "auto-repaired dnsmasq dhcpscript and dhcphostsfile integration"
	elif [ "$hook_mismatch" = "1" ]; then
		log_info "auto-repaired dnsmasq dhcpscript: $DNSMASQ_LEASE_HOOK"
	else
		log_info "auto-repaired dnsmasq dhcphostsfile: $LITE_IPAM_HOSTS_DIR"
	fi
	return 0
}

print_dnsmasq_hook_status() {
	local current_hook current_hostsfile hook_exists hook_executable hotplug_exists hotplug_executable ctl_exists ctl_executable dnsmasq_init_exists dnsmasq_init_executable enabled section_name section_hooks section_hostsfiles mismatched_sections mismatched_hostsfile_sections hook_all_match hostsfile_all_match dnsmasq_sections target_sections selected_interfaces

	command -v uci >/dev/null 2>&1 || {
		printf 'action=hook_status\n'
		printf 'uci_available=0\n'
		return 0
	}

	current_hook="$(uci -q get ${DNSMASQ_UCI_PACKAGE}.${DNSMASQ_MAIN_SECTION}.dhcpscript 2>/dev/null)"
	current_hostsfile="$(uci -q get ${DNSMASQ_UCI_PACKAGE}.${DNSMASQ_MAIN_SECTION}.dhcphostsfile 2>/dev/null)"
	enabled="$(uci -q get ${UCI_PACKAGE}.@core[0].enabled 2>/dev/null)"
	[ -n "$enabled" ] || enabled="1"
	selected_interfaces="$(uci_typed_get sync subnet_interfaces "")"
	load_core_config >/dev/null 2>&1 || true
	derive_paths
	target_sections="$(list_target_dnsmasq_sections)"
	section_hooks=""
	section_hostsfiles=""
	mismatched_sections=""
	mismatched_hostsfile_sections=""
	dnsmasq_sections=""
	hook_all_match=1
	hostsfile_all_match=1
	for section_name in $target_sections; do
		local section_hook section_hostsfile
		section_hook="$(uci -q get ${DNSMASQ_UCI_PACKAGE}.${section_name}.dhcpscript 2>/dev/null)"
		section_hostsfile="$(uci -q get ${DNSMASQ_UCI_PACKAGE}.${section_name}.dhcphostsfile 2>/dev/null)"
		dnsmasq_sections="${dnsmasq_sections}${dnsmasq_sections:+,}${section_name}"
		section_hooks="${section_hooks}${section_hooks:+,}${section_name}:${section_hook}"
		section_hostsfiles="${section_hostsfiles}${section_hostsfiles:+,}${section_name}:${section_hostsfile}"
		if [ "$section_hook" != "$DNSMASQ_LEASE_HOOK" ]; then
			hook_all_match=0
			mismatched_sections="${mismatched_sections}${mismatched_sections:+,}${section_name}"
		fi
		if [ "$section_hostsfile" != "$LITE_IPAM_HOSTS_DIR" ]; then
			hostsfile_all_match=0
			mismatched_hostsfile_sections="${mismatched_hostsfile_sections}${mismatched_hostsfile_sections:+,}${section_name}"
		fi
	done

	[ -f "$DNSMASQ_LEASE_HOOK" ] && hook_exists=1 || hook_exists=0
	[ -x "$DNSMASQ_LEASE_HOOK" ] && hook_executable=1 || hook_executable=0
	[ -f "$HOTPLUG_DHCP_HOOK" ] && hotplug_exists=1 || hotplug_exists=0
	[ -x "$HOTPLUG_DHCP_HOOK" ] && hotplug_executable=1 || hotplug_executable=0
	[ -f "$0" ] && ctl_exists=1 || ctl_exists=0
	[ -x "$0" ] && ctl_executable=1 || ctl_executable=0
	[ -f /etc/init.d/dnsmasq ] && dnsmasq_init_exists=1 || dnsmasq_init_exists=0
	[ -x /etc/init.d/dnsmasq ] && dnsmasq_init_executable=1 || dnsmasq_init_executable=0

	printf 'action=hook_status\n'
	printf 'lite_ipam_enabled=%s\n' "$(normalize_bool "$enabled")"
	printf 'selected_interfaces=%s\n' "$selected_interfaces"
	printf 'expected_hook=%s\n' "$DNSMASQ_LEASE_HOOK"
	printf 'expected_hostsfile=%s\n' "$LITE_IPAM_HOSTS_DIR"
	printf 'generated_hostsfile=%s\n' "$LITE_IPAM_HOSTS_CONF_PATH"
	printf 'expected_hotplug=%s\n' "$HOTPLUG_DHCP_HOOK"
	printf 'current_hook=%s\n' "$current_hook"
	printf 'current_hostsfile=%s\n' "$current_hostsfile"
	printf 'hook_matches=%s\n' "$( [ "$current_hook" = "$DNSMASQ_LEASE_HOOK" ] && printf 1 || printf 0 )"
	printf 'hostsfile_matches=%s\n' "$( [ "$current_hostsfile" = "$LITE_IPAM_HOSTS_DIR" ] && printf 1 || printf 0 )"
	printf 'dnsmasq_sections=%s\n' "$(list_dnsmasq_sections | tr '\n' ',' | sed 's/,$//')"
	printf 'target_sections=%s\n' "$dnsmasq_sections"
	printf 'section_hooks=%s\n' "$section_hooks"
	printf 'section_hostsfiles=%s\n' "$section_hostsfiles"
	printf 'hook_all_match=%s\n' "$hook_all_match"
	printf 'hostsfile_all_match=%s\n' "$hostsfile_all_match"
	printf 'hook_mismatched_sections=%s\n' "$mismatched_sections"
	printf 'hostsfile_mismatched_sections=%s\n' "$mismatched_hostsfile_sections"
	printf 'hook_exists=%s\n' "$hook_exists"
	printf 'hook_executable=%s\n' "$hook_executable"
	printf 'hotplug_exists=%s\n' "$hotplug_exists"
	printf 'hotplug_executable=%s\n' "$hotplug_executable"
	printf 'ctl_path=%s\n' "$0"
	printf 'ctl_exists=%s\n' "$ctl_exists"
	printf 'ctl_executable=%s\n' "$ctl_executable"
	printf 'dnsmasq_init_exists=%s\n' "$dnsmasq_init_exists"
	printf 'dnsmasq_init_executable=%s\n' "$dnsmasq_init_executable"
	printf 'note=%s\n' 'openwrt standard flow is dnsmasq wrapper -> hotplug.d/dhcp -> lite-ipam lease-event; uci value alone still does not prove runtime invocation'
	return 0
}

dnsmasq_lease_file_path() {
	local lease_file
	lease_file="$(uci -q get ${DNSMASQ_UCI_PACKAGE}.${DNSMASQ_MAIN_SECTION}.leasefile 2>/dev/null)"
	[ -n "$lease_file" ] || lease_file="/tmp/dhcp.leases"
	printf '%s' "$lease_file"
}

selected_interfaces() {
	uci_typed_get sync subnet_interfaces ""
}

managed_subnet_for_ip() {
	local ip="$1"
	local selected subnet_rows subnet_id subnet_vlan subnet_cidr subnet_iface
	selected="$(selected_interfaces)"
	[ -n "$selected" ] || return 1
	subnet_rows="${MANAGED_SUBNET_ROWS:-$(sqlite3 -batch -noheader -separator '|' "$LITE_IPAM_DB_PATH" "SELECT id, vlan_id, cidr, COALESCE(interface_name, '') FROM subnets WHERE enabled = 1 AND COALESCE(interface_name, '') <> '' ORDER BY CAST(substr(cidr, instr(cidr, '/') + 1) AS INTEGER) DESC, id ASC;")}" || return 1
	while IFS='|' read -r subnet_id subnet_vlan subnet_cidr subnet_iface; do
		[ -n "$subnet_id" ] || continue
		case " $selected " in
			*" $subnet_iface "*) ;;
			*) continue ;;
		esac
		if cidr_contains_ip "$ip" "$subnet_cidr"; then
			printf '%s|%s|%s\n' "$subnet_id" "$subnet_vlan" "$subnet_iface"
			return 0
		fi
	done <<EOF
$subnet_rows
EOF
	return 1
}

event_type_for_lease_action() {
	case "$1" in
		add) printf '%s' "lease_add" ;;
		old) printf '%s' "lease_update" ;;
		del) printf '%s' "lease_remove" ;;
		*) printf '%s' "lease_unknown" ;;
	esac
}

lease_state_for_action() {
	case "$1" in
		add|old) printf '%s' "active" ;;
		del) printf '%s' "released" ;;
		*) printf '%s' "unknown" ;;
	esac
}

prepare_runtime() {
	load_core_config || return 1
	is_enabled || return 2
	validate_data_root "$lite_ipam_data_root" || return 1
	derive_paths
	if [ -f "$LITE_IPAM_DB_PATH" ] \
		&& [ "$(sqlite3 "$LITE_IPAM_DB_PATH" 'PRAGMA user_version;')" = "2" ]; then
		return 0
	fi
	init_data_root
}

observation_table_sql() {
	cat <<'EOF'
BEGIN IMMEDIATE;
CREATE TEMP TABLE observed (
 mac TEXT NOT NULL, ip TEXT NOT NULL, hostname TEXT,
 subnet_id INTEGER NOT NULL, vlan_id INTEGER NOT NULL,
 lease_end TEXT, lease_duration INTEGER, expiry_kind TEXT NOT NULL,
 PRIMARY KEY(subnet_id, mac), UNIQUE(subnet_id, ip)
);
EOF
}

observation_row_sql() {
	printf "INSERT INTO observed VALUES ('%s','%s',NULLIF('%s',''),%s,%s,%s,%s,'%s');\n" \
		"$(sql_escape "$mac")" "$(sql_escape "$ip")" "$(sql_escape "$hostname")" \
		"$subnet_id" "$vlan_id" "$lease_end_sql" "$lease_duration_sql" "$expiry_kind"
}

apply_observations_sql() {
	local now="$1" source="$2"
	cat <<EOF
INSERT INTO events (event_type,mac,ip,hostname,subnet_id,vlan_id,detail,created_at)
SELECT 'lease_ip_conflict',o.mac,o.ip,o.hostname,o.subnet_id,o.vlan_id,
       'existing_host_id=' || h.id || ' fixed_mac=' || h.mac,'$now'
FROM observed o JOIN hosts h ON h.ip=o.ip AND h.mac<>o.mac
WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.event_type='lease_ip_conflict'
 AND e.mac=o.mac AND e.ip=o.ip AND e.detail='existing_host_id=' || h.id || ' fixed_mac=' || h.mac);
INSERT INTO events (event_type,mac,ip,hostname,subnet_id,vlan_id,detail,created_at)
SELECT 'lease_ip_drift',o.mac,o.ip,o.hostname,o.subnet_id,o.vlan_id,
       'host_id=' || h.id || ' fixed_ip=' || h.ip,'$now'
FROM observed o JOIN hosts h ON h.mac=o.mac AND h.ip<>o.ip
WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.event_type='lease_ip_drift'
 AND e.mac=o.mac AND e.ip=o.ip AND e.detail='host_id=' || h.id || ' fixed_ip=' || h.ip);

CREATE TEMP TABLE created_hosts AS
SELECT o.* FROM observed o
WHERE NOT EXISTS (SELECT 1 FROM hosts h WHERE h.mac=o.mac OR h.ip=o.ip);
INSERT INTO hosts (mac,ip,hostname,subnet_id,vlan_id,reserved,enabled,source,
 reservation_type,sync_status,created_at,updated_at,last_seen)
SELECT mac,ip,hostname,subnet_id,vlan_id,1,1,'dhcp_observed','auto','observed','$now','$now','$now'
FROM created_hosts;

UPDATE leases SET state='superseded',updated_at='$now',lease_end=COALESCE(lease_end,'$now')
WHERE state='active' AND EXISTS (
 SELECT 1 FROM observed o WHERE o.subnet_id=leases.subnet_id
 AND ((o.mac=leases.mac AND o.ip<>leases.ip) OR (o.ip=leases.ip AND o.mac<>leases.mac)));

UPDATE leases AS l SET
 hostname=COALESCE(o.hostname,l.hostname),
 lease_end=CASE WHEN o.expiry_kind='duration_only' AND l.expiry_kind='hook_remaining' THEN l.lease_end ELSE o.lease_end END,
 expiry_kind=CASE WHEN o.expiry_kind='duration_only' AND l.expiry_kind='hook_remaining' THEN l.expiry_kind ELSE o.expiry_kind END,
 lease_duration=o.lease_duration,seen_at='$now',updated_at='$now',source='$source'
FROM observed o WHERE l.state='active' AND l.subnet_id=o.subnet_id AND l.mac=o.mac AND l.ip=o.ip;
INSERT INTO leases (mac,ip,hostname,subnet_id,vlan_id,lease_start,lease_end,
 lease_duration,expiry_kind,state,seen_at,updated_at,source)
SELECT o.mac,o.ip,o.hostname,o.subnet_id,o.vlan_id,'$now',o.lease_end,
 o.lease_duration,o.expiry_kind,'active','$now','$now','$source'
FROM observed o WHERE NOT EXISTS (
 SELECT 1 FROM leases l WHERE l.state='active' AND l.subnet_id=o.subnet_id AND l.mac=o.mac AND l.ip=o.ip);
UPDATE hosts SET last_seen='$now'
WHERE EXISTS (SELECT 1 FROM observed o WHERE o.mac=hosts.mac);
EOF
}

run_lease_event() {
	local ready
	prepare_runtime
	ready=$?
	[ "$ready" -ne 2 ] || { printf 'action=lease_event\nskipped=disabled\n'; return 0; }
	[ "$ready" -eq 0 ] || return 1
	with_runtime_lock leases lease_event_locked "$@"
}

lease_event_locked() {
	local action="" mac="" ip="" hostname="" now match subnet_id vlan_id subnet_iface sql_file created
	local lease_end_sql=NULL lease_duration_sql=NULL expiry_kind=unknown
	while [ "$#" -gt 0 ]; do
		[ "$#" -ge 2 ] || { log_error "missing lease-event argument value: $1"; return 1; }
		case "$1" in
			--action) action="$2" ;;
			--mac) mac="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" ;;
			--ip) ip="$2" ;;
			--hostname) hostname="$2" ;;
			*) log_error "unknown lease-event argument: $1"; return 1 ;;
		esac
		shift 2
	done
	case "$action" in add|old|del) ;; *) log_error "invalid lease action: $action"; return 1 ;; esac
	valid_mac "$mac" && valid_ipv4 "$ip" || { log_error "invalid lease address: $mac $ip"; return 1; }
	[ "$hostname" != "*" ] || hostname=""
	if ! valid_hostname "$hostname"; then
		log_error "ignoring invalid DHCP hostname for $mac: $hostname"
		hostname=""
	fi
	match="$(managed_subnet_for_ip "$ip")"
	if [ -z "$match" ]; then
		printf 'action=lease_event\nmatched=0\n'
		return 0
	fi
	subnet_id="${match%%|*}"; match="${match#*|}"
	vlan_id="${match%%|*}"; subnet_iface="${match#*|}"
	now="$(current_timestamp)"
	sql_file="$LITE_IPAM_TMP_DIR/lease.event.$$.sql"
	observation_table_sql > "$sql_file" || return 1
	if [ "$action" != del ]; then
		if is_uint "$DNSMASQ_LEASE_EXPIRES" && [ "$DNSMASQ_LEASE_EXPIRES" -gt 0 ]; then
			lease_end_sql="strftime('%Y-%m-%dT%H:%M:%SZ',$DNSMASQ_LEASE_EXPIRES,'unixepoch')"
			expiry_kind=absolute
		elif is_uint "$DNSMASQ_TIME_REMAINING"; then
			lease_end_sql="strftime('%Y-%m-%dT%H:%M:%SZ','now','+$DNSMASQ_TIME_REMAINING seconds')"
			expiry_kind=hook_remaining
		fi
		if is_uint "$DNSMASQ_LEASE_LENGTH"; then
			lease_duration_sql="$DNSMASQ_LEASE_LENGTH"
			[ "$DNSMASQ_LEASE_LENGTH" -ne 0 ] || expiry_kind=infinite
		fi
		observation_row_sql >> "$sql_file"
		apply_observations_sql "$now" dnsmasq_hook >> "$sql_file"
	else
		cat >> "$sql_file" <<EOF
CREATE TEMP TABLE created_hosts (mac TEXT);
UPDATE leases SET state='released',lease_end='$now',updated_at='$now'
WHERE state='active' AND subnet_id=$subnet_id AND mac='$mac' AND ip='$ip';
EOF
	fi
	cat >> "$sql_file" <<EOF
INSERT INTO events (event_type,mac,ip,hostname,subnet_id,vlan_id,detail,created_at)
VALUES ('$(event_type_for_lease_action "$action")','$mac','$ip',NULLIF('$(sql_escape "$hostname")',''),
 $subnet_id,$vlan_id,'action=$action interface=$(sql_escape "$subnet_iface")','$now');
COMMIT;
SELECT count(*) FROM created_hosts;
EOF
	created="$(sqlite3 -noheader "$LITE_IPAM_DB_PATH" < "$sql_file")"
	local result=$?
	rm -f "$sql_file"
	if [ "$result" -ne 0 ]; then
		write_status_json hook false "lease hook sqlite update failed" "\"matched\": true, \"mac\": \"$mac\", \"ip\": \"$ip\", \"action\": \"$action\""
		return 1
	fi
	[ "$created" -eq 0 ] || reload_dnsmasq_deferred || return 1
	write_status_json hook true "lease hook applied" "\"matched\": true, \"mac\": \"$mac\", \"ip\": \"$ip\", \"action\": \"$action\", \"interface\": \"$(json_escape "$subnet_iface")\", \"host_created\": $([ "$created" -gt 0 ] && printf true || printf false)"
	printf 'action=lease_event\nmatched=1\nhost_created=%s\n' "$created"
}

run_lease_sync() {
	local ready
	prepare_runtime
	ready=$?
	[ "$ready" -ne 2 ] || { printf 'action=lease_sync\nskipped=disabled\n'; return 0; }
	[ "$ready" -eq 0 ] || return 1
	with_runtime_lock leases lease_sync_locked
}

lease_sync_locked() {
	local now now_epoch sql_file section lease_file files="" snapshot before after version
	local expiry mac ip hostname clientid extra match subnet_id vlan_id lease_end_sql lease_duration_sql expiry_kind
	local records=0 ignored=0 created result scope
	now="$(current_timestamp)"; now_epoch="$(date +%s)"
	sql_file="$LITE_IPAM_TMP_DIR/leases.sync.$$.sql"
	scope="$(selected_interface_sql_list)" || {
		write_status_json lease-sync false "no subnet interfaces selected"
		return 1
	}
	MANAGED_SUBNET_ROWS="$(sqlite3 -noheader -separator '|' "$LITE_IPAM_DB_PATH" "SELECT id,vlan_id,cidr,interface_name FROM subnets WHERE enabled=1 ORDER BY CAST(substr(cidr,instr(cidr,'/')+1) AS INTEGER) DESC,id;")" || return 1
	version="$(dnsmasq --version)" || return 1
	observation_table_sql > "$sql_file" || return 1
	for section in $(list_target_dnsmasq_sections); do
		lease_file="$(uci -q get "dhcp.$section.leasefile")"
		[ -n "$lease_file" ] || lease_file=/tmp/dhcp.leases
		case "
$files
" in *"
$lease_file
"*) continue ;; esac
		files="${files}${files:+
}$lease_file"
		snapshot="$LITE_IPAM_TMP_DIR/leases.snapshot.$$"
		if [ ! -f "$lease_file" ] || ! cp "$lease_file" "$snapshot"; then
			rm -f "$snapshot" "$sql_file"
			write_status_json lease-sync false "lease snapshot unavailable; existing leases retained" "\"path\": \"$(json_escape "$lease_file")\""
			return 1
		fi
		before="$(file_checksum "$snapshot")" || return 1
		after="$(file_checksum "$lease_file")" || return 1
		[ "$before" = "$after" ] || {
			rm -f "$snapshot" "$sql_file"
			write_status_json lease-sync false "lease file changed during snapshot; retry required"
			return 1
		}
		while read -r expiry mac ip hostname clientid extra || [ -n "$expiry" ]; do
			[ -n "$expiry" ] || continue
			case "$expiry" in duid) ignored=$((ignored + 1)); continue ;; esac
			case "$ip" in *:*) ignored=$((ignored + 1)); continue ;; esac
			if ! is_uint "$expiry" || ! valid_mac "$mac" || ! valid_ipv4 "$ip" || [ -n "$extra" ]; then
				rm -f "$snapshot" "$sql_file"
				write_status_json lease-sync false "malformed lease snapshot; existing leases retained" "\"path\": \"$(json_escape "$lease_file")\""
				return 1
			fi
			match="$(managed_subnet_for_ip "$ip")"
			[ -n "$match" ] || { ignored=$((ignored + 1)); continue; }
			subnet_id="${match%%|*}"; match="${match#*|}"; vlan_id="${match%%|*}"
			mac="$(printf '%s' "$mac" | tr 'A-Z' 'a-z')"
			[ "$hostname" != "*" ] || hostname=""
			if ! valid_hostname "$hostname"; then
				log_error "ignoring invalid lease hostname for $mac: $hostname"
				hostname=""
			fi
			lease_end_sql=NULL; lease_duration_sql=NULL; expiry_kind=infinite
			if [ "$expiry" -ne 0 ]; then
				case "$version" in
					*" no-RTC "*)
						lease_duration_sql="$expiry"
						expiry_kind=duration_only
						;;
					*)
						[ "$expiry" -gt "$now_epoch" ] || { ignored=$((ignored + 1)); continue; }
						lease_end_sql="strftime('%Y-%m-%dT%H:%M:%SZ',$expiry,'unixepoch')"
						expiry_kind=absolute
						;;
				esac
			fi
			observation_row_sql >> "$sql_file"
			records=$((records + 1))
		done < "$snapshot"
		rm -f "$snapshot"
	done
	cat >> "$sql_file" <<EOF
UPDATE leases SET state='expired',updated_at='$now',lease_end=COALESCE(lease_end,'$now')
WHERE state='active'
 AND subnet_id IN (SELECT id FROM subnets WHERE enabled=1 AND interface_name IN ($scope))
 AND NOT EXISTS (SELECT 1 FROM observed o WHERE o.subnet_id=leases.subnet_id AND o.mac=leases.mac AND o.ip=leases.ip);
EOF
	apply_observations_sql "$now" dnsmasq_file >> "$sql_file"
	printf 'COMMIT;\nSELECT count(*) FROM created_hosts;\n' >> "$sql_file"
	created="$(sqlite3 -noheader "$LITE_IPAM_DB_PATH" < "$sql_file")"
	result=$?
	rm -f "$sql_file"
	[ "$result" -eq 0 ] || {
		write_status_json lease-sync false "lease reconciliation failed; transaction rolled back"
		return 1
	}
	[ "$created" -eq 0 ] || reload_dnsmasq_deferred || return 1
	write_status_json lease-sync true "dnsmasq lease snapshot reconciled" "\"records\": $records, \"ignored\": $ignored, \"hosts_created\": $created, \"paths\": \"$(json_escape "$files")\""
	printf 'action=lease_sync\nrecords=%s\nignored=%s\nhosts_created=%s\n' "$records" "$ignored" "$created"
}

export_hosts_json() {
	local output_path="$1"
	sqlite3 -batch -json "$LITE_IPAM_DB_PATH" "SELECT * FROM hosts ORDER BY id ASC;" > "$output_path" || return 1
}

export_subnets_json() {
	local output_path="$1"
	sqlite3 -batch -json "$LITE_IPAM_DB_PATH" "SELECT * FROM subnets ORDER BY id ASC;" > "$output_path" || return 1
}

export_leases_json() {
	local output_path="$1"
	sqlite3 -batch -json "$LITE_IPAM_DB_PATH" "SELECT * FROM leases ORDER BY updated_at DESC, id DESC;" > "$output_path" || return 1
}

export_events_json() {
	local output_path="$1"
	sqlite3 -batch -json "$LITE_IPAM_DB_PATH" "SELECT * FROM events ORDER BY id DESC;" > "$output_path" || return 1
}

selected_interface_sql_list() {
	local selected interface_name sql_list=""
	selected="$(uci_typed_get sync subnet_interfaces "")"
	for interface_name in $selected; do
		[ -n "$interface_name" ] || continue
		sql_list="${sql_list:+$sql_list, }'$(sql_escape "$interface_name")'"
	done
	[ -n "$sql_list" ] || return 1
	printf '%s' "$sql_list"
}

run_export_hosts() {
	local output_path
	init_data_root || return 1
	output_path="$LITE_IPAM_EXPORT_DIR/hosts.json"
	export_hosts_json "$output_path" || {
		write_status_json "export" false "failed to export hosts json"
		return 1
	}
	write_status_json "export" true "exported hosts json" "\"type\": \"hosts\", \"path\": \"$(json_escape "$output_path")\""
	printf '%s\n' "$output_path"
}

run_export_dnsmasq() {
	local output_path
	init_data_root || return 1
	reload_dnsmasq_deferred || return 1
	with_runtime_lock publication generate_hosts_conf || return 1
	output_path="$LITE_IPAM_EXPORT_DIR/dnsmasq-hosts.conf"
	cp "$LITE_IPAM_HOSTS_CONF_PATH" "$output_path" || {
		write_status_json "export" false "failed to export dnsmasq hosts file"
		return 1
	}
	write_status_json "export" true "exported dnsmasq hosts file" "\"type\": \"dnsmasq\", \"path\": \"$(json_escape "$output_path")\""
	printf '%s\n' "$output_path"
}

run_export_scope() {
	local hosts_json subnets_json leases_json events_json scope_path timestamp interface_sql scope_subquery
	init_data_root || return 1
	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
	scope_path="$LITE_IPAM_EXPORT_DIR/scope-$timestamp.json"
	interface_sql="$(selected_interface_sql_list)" || {
		write_status_json "export" false "no selected subnet interfaces for scoped export"
		return 1
	}
	scope_subquery="SELECT id FROM subnets WHERE enabled = 1 AND COALESCE(interface_name, '') IN ($interface_sql)"

	subnets_json="$(sqlite3 -batch -json "$LITE_IPAM_DB_PATH" "SELECT * FROM subnets WHERE id IN ($scope_subquery) ORDER BY id ASC;" 2>/dev/null)" || return 1
	hosts_json="$(sqlite3 -batch -json "$LITE_IPAM_DB_PATH" "SELECT * FROM hosts WHERE subnet_id IN ($scope_subquery) ORDER BY id ASC;" 2>/dev/null)" || return 1
	leases_json="$(sqlite3 -batch -json "$LITE_IPAM_DB_PATH" "SELECT * FROM leases WHERE subnet_id IN ($scope_subquery) ORDER BY updated_at DESC, id DESC;" 2>/dev/null)" || return 1
	events_json="$(sqlite3 -batch -json "$LITE_IPAM_DB_PATH" "SELECT * FROM events WHERE subnet_id IS NULL OR subnet_id IN ($scope_subquery) ORDER BY id DESC;" 2>/dev/null)" || return 1

	cat > "$scope_path" <<EOF
{
  "exported_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "scope": "selected_interfaces",
  "interfaces": "$(json_escape "$(uci_typed_get sync subnet_interfaces "")")",
  "node_name": "$(json_escape "$lite_ipam_node_name")",
  "data_root": "$(json_escape "$lite_ipam_data_root")",
  "hosts": ${hosts_json:-[]},
  "subnets": ${subnets_json:-[]},
  "leases": ${leases_json:-[]},
  "events": ${events_json:-[]}
}
EOF
	write_status_json "export" true "exported scoped snapshot" "\"type\": \"scope\", \"path\": \"$(json_escape "$scope_path")\""
	printf '%s\n' "$scope_path"
}

run_export_full() {
	local hosts_json subnets_json leases_json events_json full_path timestamp
	init_data_root || return 1
	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
	full_path="$LITE_IPAM_EXPORT_DIR/full-$timestamp.json"

	hosts_json="$(sqlite3 -batch -json "$LITE_IPAM_DB_PATH" "SELECT * FROM hosts ORDER BY id ASC;" 2>/dev/null)" || return 1
	subnets_json="$(sqlite3 -batch -json "$LITE_IPAM_DB_PATH" "SELECT * FROM subnets ORDER BY id ASC;" 2>/dev/null)" || return 1
	leases_json="$(sqlite3 -batch -json "$LITE_IPAM_DB_PATH" "SELECT * FROM leases ORDER BY updated_at DESC, id DESC;" 2>/dev/null)" || return 1
	events_json="$(sqlite3 -batch -json "$LITE_IPAM_DB_PATH" "SELECT * FROM events ORDER BY id DESC;" 2>/dev/null)" || return 1

	cat > "$full_path" <<EOF
{
  "exported_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "node_name": "$(json_escape "$lite_ipam_node_name")",
  "data_root": "$(json_escape "$lite_ipam_data_root")",
  "hosts": ${hosts_json:-[]},
  "subnets": ${subnets_json:-[]},
  "leases": ${leases_json:-[]},
  "events": ${events_json:-[]}
}
EOF
	write_status_json "export" true "exported full snapshot" "\"type\": \"full\", \"path\": \"$(json_escape "$full_path")\""
	printf '%s\n' "$full_path"
}

run_backup_now() {
	local timestamp archive_path tmp_archive snapshot_dir snapshot_root item result=0
	init_data_root || return 1
	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
	archive_path="$LITE_IPAM_BACKUP_DIR/lite-ipam-$timestamp.tar.gz"
	tmp_archive="${TMPDIR:-/tmp}/lite-ipam-$timestamp.$$.tar.gz"
	snapshot_dir="$(mktemp -d "$LITE_IPAM_TMP_DIR/backup.XXXXXX")" || return 1
	snapshot_root="$snapshot_dir/$(basename "$lite_ipam_data_root")"
	mkdir -p "$snapshot_root/db" || result=1
	if [ "$result" -eq 0 ]; then
		sqlite3 "$LITE_IPAM_DB_PATH" ".backup '$snapshot_root/db/ipam.db'" || result=1
		for item in dnsmasq logs export meta.json README.md; do
			[ ! -e "$lite_ipam_data_root/$item" ] || cp -a "$lite_ipam_data_root/$item" "$snapshot_root/" || result=1
		done
	fi
	[ "$result" -ne 0 ] || tar -C "$snapshot_dir" -czf "$tmp_archive" "$(basename "$lite_ipam_data_root")" || result=1
	rm -r "$snapshot_dir"
	[ "$result" -eq 0 ] || {
		rm -f "$tmp_archive"
		write_status_json backup false "failed to create consistent backup archive"
		return 1
	}
	mv "$tmp_archive" "$archive_path" || {
		rm -f "$tmp_archive"
		write_status_json "backup" false "failed to move backup archive into backup directory"
		return 1
	}
	prune_old_backups || {
		write_status_json "backup" false "backup created but retention cleanup failed" "\"archive\": \"$(json_escape "$archive_path")\""
		return 1
	}
	if [ "$lite_ipam_backup_mail_enabled" = "1" ] || [ "$lite_ipam_backup_mail_enabled" = "true" ]; then
		send_backup_mail "$archive_path" || {
			write_status_json "backup" false "backup created but mail send failed" "\"archive\": \"$(json_escape "$archive_path")\""
			return 1
		}
	fi
	write_status_json "backup" true "backup archive created" "\"archive\": \"$(json_escape "$archive_path")\""
	printf '%s\n' "$archive_path"
}

run_cleanup_runtime() {
	local cleanup_output lease_deleted event_deleted vacuum_performed
	init_data_root || return 1
	load_maintenance_config || return 1
	if [ "$lite_ipam_maintenance_enabled" != "1" ] && [ "$lite_ipam_maintenance_enabled" != "true" ]; then
		write_status_json "cleanup" true "runtime cleanup disabled by configuration"
		return 0
	fi
	cleanup_output="$(sqlite3 -batch -noheader "$LITE_IPAM_DB_PATH" <<EOF
BEGIN IMMEDIATE;
DELETE FROM leases
WHERE state <> 'active'
  AND updated_at <> ''
  AND julianday(replace(replace(updated_at, 'T', ' '), 'Z', '')) < julianday('now', '-${lite_ipam_lease_retention_days} day');
SELECT changes();
DELETE FROM events
WHERE created_at <> ''
  AND julianday(replace(replace(created_at, 'T', ' '), 'Z', '')) < julianday('now', '-${lite_ipam_event_retention_days} day');
SELECT changes();
COMMIT;
EOF
)" || {
		write_status_json "cleanup" false "sqlite cleanup failed"
		return 1
	}
	lease_deleted="$(printf '%s\n' "$cleanup_output" | sed -n '1p')"
	event_deleted="$(printf '%s\n' "$cleanup_output" | sed -n '2p')"
	case "$lease_deleted" in
		*[!0-9]*|"") lease_deleted=0 ;;
	esac
	case "$event_deleted" in
		*[!0-9]*|"") event_deleted=0 ;;
	esac
	vacuum_performed=false
	if [ "$lite_ipam_vacuum_after_cleanup" = "1" ] || [ "$lite_ipam_vacuum_after_cleanup" = "true" ]; then
		sqlite3 "$LITE_IPAM_DB_PATH" "VACUUM;" >/dev/null 2>&1 || {
			write_status_json "cleanup" false "cleanup applied but vacuum failed" "\"leases_deleted\": $lease_deleted, \"events_deleted\": $event_deleted"
			return 1
		}
		vacuum_performed=true
	fi
	write_status_json "cleanup" true "runtime cleanup completed" "\"leases_deleted\": $lease_deleted, \"events_deleted\": $event_deleted, \"lease_retention_days\": $lite_ipam_lease_retention_days, \"event_retention_days\": $lite_ipam_event_retention_days, \"vacuum_performed\": $vacuum_performed"
	printf 'leases_deleted=%s\nevents_deleted=%s\nvacuum_performed=%s\n' "$lease_deleted" "$event_deleted" "$vacuum_performed"
}

collect_system_subnet_records() {
	local records_path="$1"
	shift
	local filter_list="$*"
	local dhcp_sections dhcp_section iface ipaddr netmask prefix address cidr gateway dns_pair dns1 dns2 start limit lease_time ignore ifname vlan_id enabled range_pair range_start range_end proto
	: > "$records_path" || return 1
	config_load network
	config_load dhcp
	dhcp_sections="$(uci -q show dhcp | sed -n 's/^dhcp\.\([^.=]*\)=dhcp$/\1/p')"
	for dhcp_section in $dhcp_sections; do
		config_get iface "$dhcp_section" interface
		[ -n "$iface" ] || continue
		if [ -n "$filter_list" ]; then
			case " $filter_list " in
				*" $iface "*) ;;
				*) continue ;;
			esac
		fi
		config_get proto "$iface" proto
		case "$proto" in
			dhcp|pppoe|none) continue ;;
		esac
		ipaddr="$(network_interface_ipaddr "$iface")"
		[ -n "$ipaddr" ] || continue
		config_get netmask "$iface" netmask
		prefix="$(cidr_prefix "$ipaddr" "$netmask" 2>/dev/null)" || continue
		address="$(cidr_address "$ipaddr")"
		cidr="$address/$prefix"
		gateway="$(network_interface_gateway "$iface" "$address")"
		dns_pair="$(network_interface_dns_pair "$iface")"
		dns1="${dns_pair%%|*}"
		dns2="${dns_pair#*|}"
		config_get start "$dhcp_section" start
		config_get limit "$dhcp_section" limit
		config_get lease_time "$dhcp_section" leasetime
		config_get ignore "$dhcp_section" ignore
		ifname="$(network_interface_device_name "$iface")"
		vlan_id="$(derive_vlan_id "$iface" "$ifname")"
		enabled=1
		[ "$(normalize_bool "$ignore")" = "1" ] && enabled=0
		range_start=""
		range_end=""
		if is_uint "$start" && is_uint "$limit" && [ "$limit" -gt 0 ]; then
			range_pair="$(compute_dhcp_range "$cidr" "$start" "$limit" 2>/dev/null)"
			range_start="${range_pair%%|*}"
			range_end="${range_pair#*|}"
		fi
		printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
			"$iface" "$vlan_id" "$cidr" "$gateway" "$dns1" "$dns2" "$range_start" "$range_end" "$lease_time" "$enabled" "$ifname" >> "$records_path"
	done
}

run_subnet_sync_system() {
	local records_path sql_file timestamp record_count sqlite_output sqlite_status
	local interface_filters="" sync_scope_sql="WHERE source = 'system'"
	init_data_root || {
		write_status_json "subnet-sync" false "failed to initialize storage for subnet synchronization"
		return 1
	}
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--interface)
				[ -n "$2" ] || { log_error "missing value for --interface"; return 1; }
				interface_filters="${interface_filters:+$interface_filters }$2"
				shift 2
				;;
			*)
				log_error "unknown subnet-sync argument: $1"
				return 1
				;;
		esac
	done
	if [ -n "$interface_filters" ]; then
		local interface_name interface_sql=""
		for interface_name in $interface_filters; do
			[ -n "$interface_name" ] || continue
			interface_sql="${interface_sql:+$interface_sql, }'$(sql_escape "$interface_name")'"
		done
		[ -n "$interface_sql" ] && sync_scope_sql="$sync_scope_sql AND COALESCE(interface_name, '') IN ($interface_sql)"
	fi
	records_path="$LITE_IPAM_TMP_DIR/subnets.sync.$$"
	sql_file="$LITE_IPAM_TMP_DIR/subnets.sync.sql.$$"
	timestamp="$(current_timestamp)"
	record_count=0
	collect_system_subnet_records "$records_path" $interface_filters || {
		write_status_json "subnet-sync" false "failed to collect system subnets"
		return 1
	}
	cat > "$sql_file" <<EOF
PRAGMA foreign_keys = ON;
BEGIN IMMEDIATE;
UPDATE subnets
SET sync_status = 'missing',
    updated_at = '$timestamp'
$sync_scope_sql;
EOF
	while IFS='|' read -r iface vlan_id cidr gateway dns1 dns2 range_start range_end lease_time enabled ifname; do
		[ -n "$iface" ] || continue
		cat >> "$sql_file" <<EOF
INSERT INTO subnets (
    vlan_id, name, cidr, interface_name, gateway, dns1, dns2, range_start, range_end,
    lease_time, display_name, comment, source, sync_status, enabled, created_at, updated_at
) VALUES (
    $vlan_id,
    '$(sql_escape "$iface")',
    '$(sql_escape "$cidr")',
    '$(sql_escape "$iface")',
    NULLIF('$(sql_escape "$gateway")', ''),
    NULLIF('$(sql_escape "$dns1")', ''),
    NULLIF('$(sql_escape "$dns2")', ''),
    NULLIF('$(sql_escape "$range_start")', ''),
    NULLIF('$(sql_escape "$range_end")', ''),
    NULLIF('$(sql_escape "$lease_time")', ''),
    '$(sql_escape "$iface")',
    NULL,
    'system',
    'synced',
    $enabled,
    '$timestamp',
    '$timestamp'
)
ON CONFLICT(interface_name) DO UPDATE SET
    vlan_id = excluded.vlan_id,
    name = excluded.name,
    cidr = excluded.cidr,
    gateway = excluded.gateway,
    dns1 = excluded.dns1,
    dns2 = excluded.dns2,
    range_start = excluded.range_start,
    range_end = excluded.range_end,
    lease_time = excluded.lease_time,
    source = 'system',
    sync_status = 'synced',
    enabled = excluded.enabled,
    updated_at = excluded.updated_at,
    display_name = COALESCE(NULLIF(subnets.display_name, ''), excluded.name),
    comment = subnets.comment;
EOF
		record_count=$((record_count + 1))
	done < "$records_path"
	if [ "$record_count" -eq 0 ]; then
		rm -f "$records_path" "$sql_file"
		if [ -n "$interface_filters" ]; then
			write_status_json "subnet-sync" false "no matching DHCP service interface found for selected interface" "\"interfaces\": \"$(json_escape "$interface_filters")\""
		else
			write_status_json "subnet-sync" false "no DHCP service interface found for synchronization"
		fi
		return 1
	fi
	printf 'COMMIT;\n' >> "$sql_file"
	sqlite_output="$(sqlite3 "$LITE_IPAM_DB_PATH" < "$sql_file" 2>&1)"
	sqlite_status="$?"
	if [ "$sqlite_status" -ne 0 ]; then
		rm -f "$records_path" "$sql_file"
		write_status_json "subnet-sync" false "failed to sync system subnets" "\"detail\": \"$(json_escape "$sqlite_output")\""
		return 1
	fi
	rm -f "$records_path" "$sql_file"
	write_status_json "subnet-sync" true "system subnets synchronized" "\"records\": $record_count, \"interfaces\": \"$(json_escape "$interface_filters")\""
	printf 'records=%s\naction=subnet_sync\ninterfaces=%s\n' "$record_count" "$interface_filters"
}

run_subnet_preview() {
	local records_path="/tmp/lite-ipam.subnets.preview.$$"
	local interface_filters=""
	local preview_count=0
	local iface vlan_id cidr gateway dns1 dns2 range_start range_end lease_time enabled ifname
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--interface)
				[ -n "$2" ] || { log_error "missing value for --interface"; return 1; }
				interface_filters="${interface_filters:+$interface_filters }$2"
				shift 2
				;;
			*)
				log_error "unknown subnet-preview argument: $1"
				return 1
				;;
		esac
	done
	collect_system_subnet_records "$records_path" $interface_filters || {
		if [ -n "$interface_filters" ]; then
			printf 'preview_count=0\ninterfaces=%s\nmessage=%s\n' "$interface_filters" "no matching DHCP service interface found for selected interface"
		else
			printf 'preview_count=0\ninterfaces=\nmessage=%s\n' "no DHCP service interface found for preview"
		fi
		return 0
	}
	while IFS='|' read -r iface vlan_id cidr gateway dns1 dns2 range_start range_end lease_time enabled ifname; do
		[ -n "$iface" ] || continue
		preview_count=$((preview_count + 1))
		printf 'row=%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
			"$iface" "$vlan_id" "$cidr" "$gateway" "$dns1" "$dns2" "$range_start" "$range_end" "$lease_time" "$enabled" "$ifname"
	done < "$records_path"
	rm -f "$records_path"
	printf 'preview_count=%s\ninterfaces=%s\n' "$preview_count" "$interface_filters"
	return 0
}

run_subnet_meta_update() {
	local subnet_id=""
	local display_name=""
	local comment=""
	local timestamp
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--id) subnet_id="$2"; shift 2 ;;
			--display-name) display_name="$2"; shift 2 ;;
			--comment) comment="$2"; shift 2 ;;
			*) log_error "unknown subnet-meta-update argument: $1"; return 1 ;;
		esac
	done
	init_data_root || return 1
	is_uint "$subnet_id" || { log_error "subnet id must be an unsigned integer"; return 1; }
	timestamp="$(current_timestamp)"
	sqlite3 -batch -noheader "$LITE_IPAM_DB_PATH" <<EOF >/dev/null 2>&1 || {
PRAGMA foreign_keys = ON;
BEGIN IMMEDIATE;
UPDATE subnets
SET display_name = NULLIF('$(sql_escape "$display_name")', ''),
    comment = NULLIF('$(sql_escape "$comment")', ''),
    updated_at = '$timestamp'
WHERE id = $subnet_id;
COMMIT;
EOF
		write_status_json "write" false "subnet metadata update failed" "\"subnet_id\": $subnet_id"
		return 1
	}
	write_status_json "write" true "subnet metadata updated" "\"subnet_id\": $subnet_id, \"action\": \"subnet_meta_update\""
	printf 'subnet_id=%s\naction=subnet_meta_update\n' "$subnet_id"
}

apply_host_changes_if_needed() {
	local reload_mode="${1:-immediate}"
	if [ "$lite_ipam_apply_mode" = "immediate" ]; then
		reload_dnsmasq_deferred || return 1
		if [ "$reload_mode" = "deferred" ]; then
			return 0
		else
			with_runtime_lock publication publish_hosts_locked || return 1
		fi
	fi
	return 0
}

run_host_upsert() {
	local host_id=""
	local hostname=""
	local mac=""
	local ip=""
	local subnet_id=""
	local vlan_id=""
	local host_type=""
	local owner=""
	local comment=""
	local reserved="1"
	local enabled="1"
	local reservation_type="reserved"
	local sync_status="synced"
	local timestamp source detail_sql action_name result_id selected_interfaces subnet_row subnet_iface subnet_cidr

	while [ "$#" -gt 0 ]; do
		[ "$#" -ge 2 ] || { log_error "missing host-upsert argument value: $1"; return 1; }
		case "$1" in
			--id) host_id="$2"; shift 2 ;;
			--hostname) hostname="$2"; shift 2 ;;
			--mac) mac="$2"; shift 2 ;;
			--ip) ip="$2"; shift 2 ;;
			--subnet-id) subnet_id="$2"; shift 2 ;;
			--type) host_type="$2"; shift 2 ;;
			--owner) owner="$2"; shift 2 ;;
			--comment) comment="$2"; shift 2 ;;
			--reserved) reserved="$2"; shift 2 ;;
			--enabled) enabled="$2"; shift 2 ;;
			--reservation-type) reservation_type="$2"; shift 2 ;;
			--sync-status) sync_status="$2"; shift 2 ;;
			*) log_error "unknown host-upsert argument: $1"; return 1 ;;
		esac
	done

	init_data_root || return 1
	mac="$(printf '%s' "$mac" | tr 'A-Z' 'a-z')"
	reserved="$(normalize_bool "$reserved")"
	enabled="$(normalize_bool "$enabled")"
	source="manual_ui"
	timestamp="$(current_timestamp)"
	valid_mac "$mac" || { log_error "host mac is invalid"; return 1; }
	valid_ipv4 "$ip" || { log_error "host ip is invalid"; return 1; }
	valid_hostname "$hostname" || { log_error "host hostname is invalid"; return 1; }
	is_uint "$subnet_id" || { log_error "subnet_id must be an unsigned integer"; return 1; }
	[ "$(sqlite3 -batch -noheader "$LITE_IPAM_DB_PATH" "SELECT COUNT(*) FROM subnets WHERE id = $subnet_id;" 2>/dev/null)" = "1" ] || {
		log_error "subnet id not found: $subnet_id"
		write_status_json "write" false "subnet id not found" "\"subnet_id\": $subnet_id"
		return 1
	}
	subnet_row="$(sqlite3 -batch -noheader -separator '|' "$LITE_IPAM_DB_PATH" "SELECT COALESCE(interface_name, ''), COALESCE(vlan_id, 0),cidr FROM subnets WHERE id = $subnet_id AND enabled=1 LIMIT 1;")" || return 1
	subnet_iface="${subnet_row%%|*}"
	subnet_row="${subnet_row#*|}"
	vlan_id="${subnet_row%%|*}"
	subnet_cidr="${subnet_row#*|}"
	cidr_contains_ip "$ip" "$subnet_cidr" || {
		log_error "host ip $ip is outside subnet $subnet_id"
		write_status_json write false "host ip is outside selected subnet"
		return 1
	}
	is_uint "$vlan_id" || { log_error "subnet vlan_id is invalid"; return 1; }
	selected_interfaces="$(uci_typed_get sync subnet_interfaces "")"
	[ -n "$subnet_iface" ] && [ -n "$selected_interfaces" ] || {
		log_error "subnet is outside selected interface scope: $subnet_id"
		write_status_json "write" false "subnet is outside selected interface scope" "\"subnet_id\": $subnet_id"
		return 1
	}
	case " $selected_interfaces " in
		*" $subnet_iface "*) ;;
		*)
			log_error "subnet is outside selected interface scope: $subnet_id"
			write_status_json "write" false "subnet is outside selected interface scope" "\"subnet_id\": $subnet_id"
			return 1
		;;
	esac
	if [ -n "$host_id" ]; then
		is_uint "$host_id" || { log_error "host id must be an unsigned integer"; return 1; }
		action_name="host_update"
	else
		action_name="host_create"
	fi
	detail_sql="$(sql_escape "action=$action_name source=$source")"
	if [ -n "$host_id" ]; then
		result_id="$(sqlite3 -batch -noheader "$LITE_IPAM_DB_PATH" <<EOF
PRAGMA foreign_keys = ON;
BEGIN IMMEDIATE;
UPDATE hosts
SET hostname = NULLIF('$(sql_escape "$hostname")', ''),
    mac = '$(sql_escape "$mac")',
    ip = '$(sql_escape "$ip")',
    subnet_id = $subnet_id,
    vlan_id = $vlan_id,
    type = NULLIF('$(sql_escape "$host_type")', ''),
    owner = NULLIF('$(sql_escape "$owner")', ''),
    comment = NULLIF('$(sql_escape "$comment")', ''),
    reserved = $reserved,
    enabled = $enabled,
    source = '$(sql_escape "$source")',
    reservation_type = '$(sql_escape "$reservation_type")',
    sync_status = 'pending',
    updated_at = '$timestamp'
WHERE id = $host_id;
INSERT INTO events (event_type, mac, ip, hostname, subnet_id, vlan_id, detail, created_at)
SELECT '$action_name', '$(sql_escape "$mac")', '$(sql_escape "$ip")', NULLIF('$(sql_escape "$hostname")', ''), $subnet_id, $vlan_id, '$detail_sql', '$timestamp'
WHERE EXISTS (SELECT 1 FROM hosts WHERE id = $host_id);
COMMIT;
SELECT id FROM hosts WHERE id = $host_id LIMIT 1;
EOF
)" || return 1
		result_id="$(printf '%s\n' "$result_id" | tail -n 1 | tr -d ' ')"
		is_uint "$result_id" || { log_error "host update failed"; write_status_json "write" false "host update failed"; return 1; }
	else
		result_id="$(sqlite3 -batch -noheader "$LITE_IPAM_DB_PATH" <<EOF
PRAGMA foreign_keys = ON;
BEGIN IMMEDIATE;
INSERT INTO hosts (
    hostname, mac, ip, subnet_id, vlan_id, type, owner, comment,
    reserved, enabled, source, reservation_type, sync_status, created_at, updated_at
) VALUES (
    NULLIF('$(sql_escape "$hostname")', ''),
    '$(sql_escape "$mac")',
    '$(sql_escape "$ip")',
    $subnet_id,
    $vlan_id,
    NULLIF('$(sql_escape "$host_type")', ''),
    NULLIF('$(sql_escape "$owner")', ''),
    NULLIF('$(sql_escape "$comment")', ''),
    $reserved,
    $enabled,
    '$(sql_escape "$source")',
    '$(sql_escape "$reservation_type")',
    'pending',
    '$timestamp',
    '$timestamp'
);
INSERT INTO events (event_type, mac, ip, hostname, subnet_id, vlan_id, detail, created_at)
VALUES ('$action_name', '$(sql_escape "$mac")', '$(sql_escape "$ip")', NULLIF('$(sql_escape "$hostname")', ''), $subnet_id, $vlan_id, '$detail_sql', '$timestamp');
COMMIT;
SELECT id FROM hosts WHERE mac='$(sql_escape "$mac")';
EOF
)" || return 1
		result_id="$(printf '%s\n' "$result_id" | tail -n 1 | tr -d ' ')"
		is_uint "$result_id" || { log_error "host create failed"; write_status_json "write" false "host create failed"; return 1; }
	fi
	apply_host_changes_if_needed || {
		write_status_json "write" false "host saved but dnsmasq apply failed" "\"host_id\": $result_id"
		return 1
	}
	write_status_json "write" true "host saved" "\"host_id\": $result_id, \"action\": \"$action_name\""
	printf 'host_id=%s\naction=%s\n' "$result_id" "$action_name"
}

run_host_delete() {
	local host_id="$1"
	local host_row mac ip hostname subnet_id vlan_id timestamp delete_output
	init_data_root || return 1
	is_uint "$host_id" || { log_error "host id must be an unsigned integer"; return 1; }
	host_row="$(sqlite3 -batch -noheader -separator '|' "$LITE_IPAM_DB_PATH" "SELECT COALESCE(mac, ''), COALESCE(ip, ''), COALESCE(hostname, ''), COALESCE(subnet_id, 0), COALESCE(vlan_id, 0) FROM hosts WHERE id = $host_id LIMIT 1;" 2>/dev/null)"
	[ -n "$host_row" ] || { log_error "host id not found: $host_id"; write_status_json "write" false "host id not found" "\"host_id\": $host_id"; return 1; }
	mac="$(printf '%s' "$host_row" | cut -d'|' -f1)"
	ip="$(printf '%s' "$host_row" | cut -d'|' -f2)"
	hostname="$(printf '%s' "$host_row" | cut -d'|' -f3)"
	subnet_id="$(printf '%s' "$host_row" | cut -d'|' -f4)"
	vlan_id="$(printf '%s' "$host_row" | cut -d'|' -f5)"
	timestamp="$(current_timestamp)"
	delete_output="$(sqlite3 -batch -noheader "$LITE_IPAM_DB_PATH" <<EOF
PRAGMA foreign_keys = ON;
BEGIN IMMEDIATE;
DELETE FROM hosts WHERE id = $host_id;
SELECT changes();
INSERT INTO events (event_type, mac, ip, hostname, subnet_id, vlan_id, detail, created_at)
VALUES ('host_delete', '$(sql_escape "$mac")', '$(sql_escape "$ip")', NULLIF('$(sql_escape "$hostname")', ''), $subnet_id, $vlan_id, 'action=host_delete source=manual_ui', '$timestamp');
COMMIT;
EOF
)" || return 1
	delete_output="$(printf '%s\n' "$delete_output" | sed -n '1p' | tr -d ' ')"
	[ "$delete_output" = "1" ] || { log_error "host delete failed"; write_status_json "write" false "host delete failed" "\"host_id\": $host_id"; return 1; }
	apply_host_changes_if_needed || {
		write_status_json "write" false "host deleted but dnsmasq apply failed" "\"host_id\": $host_id"
		return 1
	}
	write_status_json "write" true "host deleted" "\"host_id\": $host_id, \"action\": \"host_delete\""
	printf 'host_id=%s\naction=host_delete\n' "$host_id"
}

prune_old_backups() {
	local retention_days find_count
	retention_days="${lite_ipam_backup_retention_days:-30}"
	case "$retention_days" in
		*[!0-9]*|"") retention_days=30 ;;
	esac
	find_count="$(find "$LITE_IPAM_BACKUP_DIR" -maxdepth 1 -type f -name 'lite-ipam-*.tar.gz' -mtime +$retention_days -print -delete 2>/dev/null | wc -l | tr -d ' ')"
	[ -n "$find_count" ] || find_count=0
	return 0
}

send_backup_mail() {
	local archive_path="$1"
	local subject body tls_flag auth_args
	command -v mailsend >/dev/null 2>&1 || {
		log_error "mailsend is unavailable"
		write_status_json "mail" false "mailsend is unavailable"
		return 1
	}
	[ -n "$lite_ipam_backup_mail_to" ] || {
		log_error "backup mail recipient is empty"
		write_status_json "mail" false "backup mail recipient is empty"
		return 1
	}
	[ -n "$lite_ipam_backup_mail_from" ] || {
		log_error "backup mail sender is empty"
		write_status_json "mail" false "backup mail sender is empty"
		return 1
	}
	[ -n "$lite_ipam_backup_smtp_host" ] || {
		log_error "backup smtp host is empty"
		write_status_json "mail" false "backup smtp host is empty"
		return 1
	}
	subject="lite-ipam backup $lite_ipam_node_name $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	body="lite-ipam backup archive: $archive_path"
	tls_flag="-starttls"
	if [ "$lite_ipam_backup_smtp_tls" = "0" ] || [ "$lite_ipam_backup_smtp_tls" = "false" ]; then
		tls_flag=""
	fi
	auth_args=""
	if [ -n "$lite_ipam_backup_smtp_user" ]; then
		auth_args="1"
	fi
	set -- mailsend -smtp "$lite_ipam_backup_smtp_host" -port "$lite_ipam_backup_smtp_port"
	[ -n "$tls_flag" ] && set -- "$@" "$tls_flag"
	[ -n "$auth_args" ] && set -- "$@" -auth -user "$lite_ipam_backup_smtp_user" -pass "$lite_ipam_backup_smtp_password"
	"$@" -f "$lite_ipam_backup_mail_from" -t "$lite_ipam_backup_mail_to" \
		-sub "$subject" -msg "$body" -attach "$archive_path" >/dev/null 2>&1 || {
			log_error "failed to send backup mail"
			write_status_json "mail" false "failed to send backup mail" "\"archive\": \"$(json_escape "$archive_path")\""
			return 1
		}
	write_status_json "mail" true "backup mail sent" "\"archive\": \"$(json_escape "$archive_path")\""
	return 0
}

ensure_cron_job() {
	local cron_file cron_line escaped_line
	load_core_config || return 1
	cron_file="/etc/crontabs/root"
	cron_line="$lite_ipam_backup_cron_schedule /usr/libexec/lite-ipam/daily-backup-and-mail.sh"
	escaped_line="$(printf '%s' "$cron_line" | sed 's/[.[\*^$()+?{}|/]/\\&/g')"
	if [ "$lite_ipam_backup_cron_enabled" != "1" ] && [ "$lite_ipam_backup_cron_enabled" != "true" ]; then
		if [ -f "$cron_file" ]; then
			sed -i "\|$escaped_line|d" "$cron_file"
		fi
		/etc/init.d/cron reload >/dev/null 2>&1 || true
		return 0
	fi
	[ -f "$cron_file" ] || : > "$cron_file"
	grep -Fqx "$cron_line" "$cron_file" || printf '%s\n' "$cron_line" >> "$cron_file"
	/etc/init.d/cron reload >/dev/null 2>&1 || true
	return 0
}

init_data_root() {
	local strict_mode="${1:-1}"
	local did_init=0
	load_core_config || {
		log_error "failed to load UCI config: $UCI_PACKAGE"
		return 1
	}

	is_enabled || {
		log_info "service disabled in UCI, skipping initialization"
		return 0
	}

	if [ -z "$lite_ipam_data_root" ]; then
		if [ "$strict_mode" = "0" ]; then
			return 0
		fi
		log_error "data_root is empty"
		return 1
	fi

	validate_data_root "$lite_ipam_data_root" || return 1
	derive_paths

	if [ ! -d "$lite_ipam_data_root" ]; then
		[ "$lite_ipam_auto_init" = "1" ] || [ "$lite_ipam_auto_init" = "true" ] || {
			log_error "data_root does not exist and auto_init is disabled: $lite_ipam_data_root"
			return 1
		}
		ensure_directory "$lite_ipam_data_root" || return 1
		did_init=1
	fi

	[ -w "$lite_ipam_data_root" ] || {
		log_error "data_root is not writable: $lite_ipam_data_root"
		return 1
	}

	if [ "$lite_ipam_auto_create_subdirs" = "1" ] || [ "$lite_ipam_auto_create_subdirs" = "true" ]; then
		[ -d "$LITE_IPAM_DB_DIR" ] || did_init=1
		[ -d "$LITE_IPAM_DNSMASQ_DIR" ] || did_init=1
		[ -d "$LITE_IPAM_PENDING_DIR" ] || did_init=1
		[ -d "$LITE_IPAM_LOGS_DIR" ] || did_init=1
		[ -d "$LITE_IPAM_BACKUP_DIR" ] || did_init=1
		[ -d "$LITE_IPAM_EXPORT_DIR" ] || did_init=1
		[ -d "$LITE_IPAM_TMP_DIR" ] || did_init=1
		[ -d "$LITE_IPAM_STATUS_DIR" ] || did_init=1
		ensure_directory "$LITE_IPAM_DB_DIR" || return 1
		ensure_directory "$LITE_IPAM_DNSMASQ_DIR" || return 1
		ensure_directory "$LITE_IPAM_HOSTS_DIR" || return 1
		ensure_directory "$LITE_IPAM_PENDING_DIR" || return 1
		ensure_directory "$LITE_IPAM_LOGS_DIR" || return 1
		ensure_directory "$LITE_IPAM_BACKUP_DIR" || return 1
		ensure_directory "$LITE_IPAM_EXPORT_DIR" || return 1
		ensure_directory "$LITE_IPAM_TMP_DIR" || return 1
		ensure_directory "$LITE_IPAM_STATUS_DIR" || return 1
	fi

	[ -f "$LITE_IPAM_HOSTS_CONF_PATH" ] || did_init=1
	[ -f "$LITE_IPAM_DB_PATH" ] || did_init=1
	[ -f "$LITE_IPAM_STATUS_DIR/health.json" ] || did_init=1

	write_readme_if_missing || return 1
	write_meta_if_missing || return 1
	ensure_hosts_conf || return 1
	with_runtime_lock schema ensure_sqlite_schema || return 1
	if [ "$did_init" = "1" ] \
		|| [ ! -f "$LITE_IPAM_STATUS_DIR/health.json" ] \
		|| ! grep -q '"ok": true' "$LITE_IPAM_STATUS_DIR/health.json" 2>/dev/null \
		|| ! grep -q '"message": "data root initialized"' "$LITE_IPAM_STATUS_DIR/health.json" 2>/dev/null; then
		write_status_json "health" true "data root initialized"
	fi

	[ "$did_init" = "1" ] && log_info "initialized data_root at $lite_ipam_data_root"
	return 0
}

print_paths() {
	load_core_config || return 1
	derive_paths
	cat <<EOF
data_root=$lite_ipam_data_root
db_dir=$LITE_IPAM_DB_DIR
db_path=$LITE_IPAM_DB_PATH
dnsmasq_dir=$LITE_IPAM_DNSMASQ_DIR
hosts_conf_path=$LITE_IPAM_HOSTS_CONF_PATH
pending_dir=$LITE_IPAM_PENDING_DIR
logs_dir=$LITE_IPAM_LOGS_DIR
backup_dir=$LITE_IPAM_BACKUP_DIR
export_dir=$LITE_IPAM_EXPORT_DIR
tmp_dir=$LITE_IPAM_TMP_DIR
status_dir=$LITE_IPAM_STATUS_DIR
meta_path=$LITE_IPAM_META_PATH
readme_path=$LITE_IPAM_README_PATH
EOF
}

print_usage() {
	cat <<EOF
Usage: $0 <command>

Commands:
  init-service    Initialize lite-ipam data root from UCI config
	generate-hosts  Generate dnsmasq hosts.conf from sqlite
	apply-dnsmasq   Generate hosts.conf, wire dnsmasq, and reload it
	apply-hook      Configure dnsmasq lease hook and reload it
	repair-hook     Alias of apply-hook for manual hook repair
	hook-status     Print dnsmasq and hotplug diagnostic checkpoints
	lease-event     Persist one dnsmasq lease hook event into sqlite
	worker          Reconcile leases and publish coalesced reservation changes
	lease-sync      Synchronize current dnsmasq lease file into sqlite
	subnet-preview  Preview subnet records from selected DHCP interfaces
	subnet-sync     Synchronize system interface and DHCP subnets into sqlite
	subnet-meta     Update subnet business metadata only
	host-upsert     Create or update a host record in sqlite
	host-delete     Delete a host record from sqlite
	export-hosts    Export hosts table to JSON file
	export-scope    Export selected-interface scoped snapshot metadata
	export-full     Export hosts/subnets/leases/events snapshot metadata
	export-dnsmasq  Export generated dnsmasq hosts file
	backup-now      Archive current data_root into backup directory
	cleanup-runtime Remove expired leases/events and optionally vacuum sqlite
	ensure-cron     Ensure cron entry for daily backup script
  validate-root   Validate configured data_root only
  print-paths     Print derived runtime paths
EOF
}

cmd_validate_root() {
	load_core_config || return 1
	validate_data_root "$lite_ipam_data_root"
}

if should_auto_repair_dnsmasq_hook "$1"; then
	auto_repair_dnsmasq_lease_hook || exit 1
fi

case "$1" in
	init-service|init)
		init_data_root 0 || exit 1
		is_enabled && [ -n "$lite_ipam_data_root" ] || exit 0
		reload_dnsmasq_deferred || exit 1
		;;
	generate-hosts)
		init_data_root || exit 1
		reload_dnsmasq_deferred || exit 1
		with_runtime_lock publication generate_hosts_conf
		;;
	apply-dnsmasq)
		apply_dnsmasq_hosts
		;;
	apply-hook|repair-hook)
		apply_dnsmasq_lease_hook || exit 1
		printf 'action=apply_hook\n'
		;;
	hook-status)
		print_dnsmasq_hook_status
		;;
	lease-event)
		shift
		run_lease_event "$@" || exit 1
		;;
	worker)
		run_worker || exit 1
		;;
	lease-sync)
		run_lease_sync || exit 1
		;;
	subnet-preview)
		shift
		run_subnet_preview "$@"
		;;
	subnet-sync)
		shift
		run_subnet_sync_system "$@"
		;;
	subnet-meta)
		shift
		run_subnet_meta_update "$@"
		;;
	host-upsert)
		shift
		run_host_upsert "$@"
		;;
	host-delete)
		shift
		run_host_delete "$1"
		;;
	export-hosts)
		run_export_hosts
		;;
	export-scope)
		run_export_scope
		;;
	export-full)
		run_export_full
		;;
	export-dnsmasq)
		run_export_dnsmasq
		;;
	backup-now)
		run_backup_now
		;;
	cleanup-runtime)
		run_cleanup_runtime
		;;
	ensure-cron)
		ensure_cron_job
		;;
	validate-root)
		cmd_validate_root
		;;
	print-paths)
		print_paths
		;;
	""|-h|--help|help)
		print_usage
		;;
	*)
		log_error "unknown command: $1"
		print_usage
		exit 1
		;;
	esac