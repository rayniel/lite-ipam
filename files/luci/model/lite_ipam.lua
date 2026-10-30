local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local sys = require "luci.sys"
local jsonc = require "luci.jsonc"
local fs = require "nixio.fs"

local M = {}
local db_ready
local auto_refresh_enabled = true
local overview_summary_cache_ttl = 5
local lease_refresh_min_interval = 10
local enrich_command_error

function M.set_auto_refresh(enabled)
	auto_refresh_enabled = enabled and true or false
end

local function shellquote(value)
	return util.shellquote(value or "")
end

local function trim(value)
	return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function first_section_name(package_name, type_name)
	local section_name
	uci:foreach(package_name, type_name, function(section)
		section_name = section[".name"]
		return false
	end)
	return section_name
end

local function ensure_section_name(package_name, type_name)
	local section_name = first_section_name(package_name, type_name)
	if section_name then
		return section_name
	end
	section_name = uci:section(package_name, type_name, type_name)
	if section_name then
		return section_name
	end
	section_name = uci:section(package_name, type_name)
	if section_name then
		return section_name
	end
	return first_section_name(package_name, type_name)
end

local function typed_get(type_name, option_name, default_value)
	local value = uci:get_first("lite-ipam", type_name, option_name)
	if value == nil or value == "" then
		return default_value
	end
	return value
	end

local function typed_set(type_name, option_name, value)
	local section_name = ensure_section_name("lite-ipam", type_name)
	if not section_name then
		return false, "missing section: " .. tostring(type_name)
	end
	if not uci:set("lite-ipam", section_name, option_name, tostring(value or "")) then
		return false, "uci:set failed: " .. tostring(type_name) .. "." .. tostring(option_name)
	end
	return true, nil
end

local function split_words(value)
	local items = {}
	if type(value) == "table" then
		for _, item in ipairs(value) do
			item = tostring(item or ""):match("^%s*(.-)%s*$")
			if item ~= "" then
				items[#items + 1] = item
			end
		end
		return items
	end
	for word in tostring(value or ""):gmatch("[^,%s]+") do
		items[#items + 1] = word
	end
	return items
end

local function selected_sync_interfaces_map()
	local selected = {}
	local cursor = require "luci.model.uci".cursor()
	cursor:foreach("lite-ipam", "sync", function(section)
		for _, interface_name in ipairs(split_words(section.subnet_interfaces)) do
			selected[interface_name] = true
		end
	end)
	return selected
end

local function first_dnsmasq_section_name()
	local section_name
	uci:foreach("dhcp", "dnsmasq", function(section)
		section_name = tostring(section[".name"] or "")
		return false
	end)
	return section_name or ""
end

local function resolve_target_dnsmasq_sections()
	local selected = selected_sync_interfaces_map()
	local default_section = first_dnsmasq_section_name()
	local targets = {}
	local seen = {}
	local has_selected = next(selected) ~= nil
	local function append_target(section_name)
		section_name = tostring(section_name or "")
		if section_name == "" or seen[section_name] then
			return
		end
		seen[section_name] = true
		targets[#targets + 1] = section_name
	end

	if default_section == "" then
		return targets
	end
	if not has_selected then
		append_target(default_section)
		return targets
	end
	uci:foreach("dhcp", "dhcp", function(section)
		local interface_name = tostring(section.interface or "")
		local instance_name = tostring(section.instance or "")
		if selected[interface_name] then
			append_target(instance_name ~= "" and instance_name or default_section)
		end
	end)
	if #targets == 0 then
		append_target(default_section)
	end
	return targets
end

local function set_sync_subnet_interfaces(value)
	local targets = {}
	uci:foreach("lite-ipam", "sync", function(section)
		targets[#targets + 1] = { section = section[".name"], type_name = "sync" }
	end)
	local saw_error = false
	local error_message

	if #targets == 0 then
		local ok, err = typed_set("sync", "subnet_interfaces", value)
		if not ok then
			return false, err
		end
		return true, nil
	end

	for _, target in ipairs(targets) do
		if not uci:set("lite-ipam", target.section, "subnet_interfaces", value) then
			saw_error = true
			error_message = "uci:set failed: " .. tostring(target.type_name) .. ".subnet_interfaces"
		end
	end

	if saw_error then
		return false, error_message
	end

	return true, nil
end

local function normalize_interface_list(interfaces)
	local normalized = {}
	local seen = {}
	if type(interfaces) ~= "table" then
		return normalized
	end
	for _, interface_name in ipairs(interfaces) do
		interface_name = tostring(interface_name or ""):match("^%s*(.-)%s*$")
		if interface_name ~= "" and not seen[interface_name] then
			seen[interface_name] = true
			normalized[#normalized + 1] = interface_name
		end
	end
	table.sort(normalized)
	return normalized
end

local function map_keys_sorted(map)
	local keys = {}
	for key, enabled in pairs(map or {}) do
		if enabled then
			keys[#keys + 1] = tostring(key)
		end
	end
	table.sort(keys)
	return keys
end

local function sql_literal(value)
	return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

local function selected_subnet_scope_condition(alias)
	local selected = map_keys_sorted(selected_sync_interfaces_map())
	local column = ((alias and alias ~= "") and (alias .. ".") or "") .. "interface_name"
	local values = {}
	if #selected == 0 then
		return "0 = 1"
	end
	for _, interface_name in ipairs(selected) do
		values[#values + 1] = sql_literal(interface_name)
	end
	return string.format("COALESCE(%s, '') IN (%s)", column, table.concat(values, ", "))
end

local function selected_subnet_exists_for_host(host_alias)
	local prefix = (host_alias and host_alias ~= "") and (host_alias .. ".") or ""
	return string.format("EXISTS (SELECT 1 FROM subnets scope_subnet WHERE scope_subnet.id = %ssubnet_id AND scope_subnet.enabled = 1 AND %s)", prefix, selected_subnet_scope_condition("scope_subnet"))
end

local function selected_subnet_exists_for_lease(lease_alias)
	local prefix = (lease_alias and lease_alias ~= "") and (lease_alias .. ".") or ""
	return string.format("EXISTS (SELECT 1 FROM subnets scope_subnet WHERE scope_subnet.id = %ssubnet_id AND scope_subnet.enabled = 1 AND %s)", prefix, selected_subnet_scope_condition("scope_subnet"))
end

local function selected_subnet_id_for_lease(lease_alias)
	local prefix = (lease_alias and lease_alias ~= "") and (lease_alias .. ".") or ""
	return string.format("COALESCE(%ssubnet_id, 0)", prefix)
end

local function selected_subnet_exists_for_event(event_alias)
	local prefix = (event_alias and event_alias ~= "") and (event_alias .. ".") or ""
	return string.format("(%ssubnet_id IS NULL OR EXISTS (SELECT 1 FROM subnets scope_subnet WHERE scope_subnet.id = %ssubnet_id AND scope_subnet.enabled = 1 AND %s))", prefix, prefix, selected_subnet_scope_condition("scope_subnet"))
end

local function api_page_limits(fallback_default, fallback_max)
	local configured_max = tonumber(typed_get("api", "max_page_size", tostring(fallback_max))) or fallback_max
	local configured_default = tonumber(typed_get("api", "default_page_size", tostring(fallback_default))) or fallback_default

	if configured_max < 1 then
		configured_max = fallback_max
	end

	if configured_max > fallback_max then
		configured_max = fallback_max
	end

	if configured_default < 1 then
		configured_default = fallback_default
	end

	if configured_default > configured_max then
		configured_default = configured_max
	end

	return configured_default, configured_max
end

local function load_config()
	local data_root = uci:get_first("lite-ipam", "core", "data_root") or ""
	local enabled = uci:get_first("lite-ipam", "core", "enabled") or "0"

	return {
		enabled = (enabled == "1" or enabled == "true"),
		node_name = uci:get_first("lite-ipam", "core", "node_name") or "",
		data_root = data_root,
		db_path = data_root ~= "" and (data_root .. "/db/ipam.db") or "",
		hosts_conf_path = data_root ~= "" and (data_root .. "/dnsmasq/active/hosts.conf") or "",
		hosts_dir = data_root ~= "" and (data_root .. "/dnsmasq/active") or "",
		export_dir = data_root ~= "" and (data_root .. "/export") or "",
		log_path = data_root ~= "" and (data_root .. "/logs/runtime.log") or "",
		meta_path = data_root ~= "" and (data_root .. "/meta.json") or "",
		status_dir = data_root ~= "" and (data_root .. "/tmp/status") or "",
		ctl_path = "/usr/libexec/lite-ipam/lite-ipam.sh"
	}
end

local function storage_issue(config)
	if config.data_root == "" then
		return "data_root is not configured"
	end

	if not fs.access(config.data_root) then
		return "data_root does not exist"
	end

	if not db_ready(config) then
		return "sqlite database is unavailable"
	end

	return nil
end

local function sqlite_available()
	return sys.call("command -v sqlite3 >/dev/null 2>&1") == 0
end

local function file_writable(path)
	if not path or path == "" then
		return false
	end

	if fs.access(path) and sys.call(string.format("test -w %s >/dev/null 2>&1", shellquote(path))) == 0 then
		return true
	end

	local parent = path:match("^(.+)/[^/]+/?$")
	return parent and fs.access(parent) and sys.call(string.format("test -w %s >/dev/null 2>&1", shellquote(parent))) == 0 or false
end

local function validate_data_root_for_save(data_root, enabled)
	data_root = trim(data_root)
	if data_root == "" then
		if enabled ~= "1" and enabled ~= "true" then
			return nil
		end
		return "Data Root 不能为空，启用服务时必须指定存储目录。"
	end
	if data_root:sub(1, 1) ~= "/" then
		return "Data Root 必须是绝对路径，例如 /mnt/sata/lite-ipam。"
	end
	if data_root == "/" or data_root == "/etc" or data_root == "/tmp" or data_root == "/var" or data_root == "/root" then
		return "Data Root 不能使用系统关键目录。"
	end
	local parent = data_root:match("^(.+)/[^/]+/?$")
	if not parent or parent == "" then
		parent = "/"
	end
	if not fs.access(parent) then
		return "Data Root 的父目录不存在。"
	end
	if not fs.access(data_root) and not (fs.access(parent) and sys.call(string.format("test -w %s >/dev/null 2>&1", shellquote(parent))) == 0) then
		return "Data Root 不存在，且父目录不可写，无法自动创建。"
	end
	return nil
end

db_ready = function(config)
	return config.db_path ~= "" and fs.access(config.db_path)
end

local function sqlite_read(config, sql, separator)
	local command = string.format("sqlite3 -init /dev/null -readonly -list -batch -bail -noheader -cmd '.timeout 5000' -separator %s %s %s",
		shellquote(separator or "|"), shellquote(config.db_path), shellquote(sql))
	local probe = sys.exec(string.format("output=$(%s 2>&1); status=$?; printf '%%s\\n%%s' \"$status\" \"$output\"", command))
	local status, output = tostring(probe or ""):match("^(%d+)\n(.*)$")
	if tonumber(status) ~= 0 then
		require("nixio").syslog("err", "lite-ipam sqlite read failed: " .. tostring(output or probe))
		error("lite-ipam database read failed")
	end
	return output or ""
end

local function query_scalar(config, sql)
	if not db_ready(config) or not sqlite_available() then
		return nil
	end

	local value = sqlite_read(config, sql)
	if not value then
		return nil
	end

	value = value:gsub("%s+$", "")
	if value == "" then
		return nil
	end

	return value
end

local function query_rows(config, sql, keys, numeric_fields)
	local rows = {}

	if not db_ready(config) or not sqlite_available() then
		return rows
	end

	for line in sqlite_read(config, sql, "\t"):gmatch("[^\n]+") do
		local row = {}
		local field_index = 1
		local start_index = 1
		local line_length = #line

		for index = 1, line_length + 1 do
			if index > line_length or line:sub(index, index) == "\t" then
				local value = line:sub(start_index, index - 1)
				local key = keys[field_index]
				if key then
					if numeric_fields[key] then
						row[key] = tonumber(value) or 0
					else
						row[key] = value
					end
				end
				field_index = field_index + 1
				start_index = index + 1
			end
		end

		rows[#rows + 1] = row
	end

	return rows
end

local function enrich_host_activity_row(row)
	local lease_seen_at

	if type(row) ~= "table" then
		return row
	end

	lease_seen_at = trim(row.last_seen)
	row.lease_seen_at = lease_seen_at
	row.last_seen_source = lease_seen_at ~= "" and "lease" or ""
	row.last_activity = trim(row.last_activity)
	row.last_activity_source = trim(row.last_activity_source)

	if row.last_activity ~= "" then
		row.last_activity_state = "available"
	elseif lease_seen_at ~= "" then
		row.last_activity_state = "pending_probe"
	else
		row.last_activity_state = "unavailable"
	end

	return row
end

local function enrich_host_activity_rows(rows)
	for index, row in ipairs(rows or {}) do
		rows[index] = enrich_host_activity_row(row)
	end
	return rows
end

local function count_table(config, table_name)
	local value = query_scalar(config, string.format("SELECT COUNT(*) FROM %s;", table_name))
	return tonumber(value) or 0
end

local function scoped_count(config, table_name)
	local condition
	if table_name == "subnets" then
		condition = "enabled = 1 AND " .. selected_subnet_scope_condition()
	elseif table_name == "hosts" then
		condition = selected_subnet_exists_for_host()
	elseif table_name == "leases" then
		condition = selected_subnet_exists_for_lease()
	elseif table_name == "events" then
		condition = selected_subnet_exists_for_event()
	else
		return count_table(config, table_name)
	end
	return tonumber(query_scalar(config, string.format("SELECT COUNT(*) FROM %s WHERE %s;", table_name, condition))) or 0
end

local function overview_metrics(config)
	local rows = query_rows(config, string.format([[SELECT
		(SELECT COUNT(*) FROM subnets WHERE enabled = 1 AND %s),
		(SELECT COUNT(*) FROM hosts WHERE %s),
		(SELECT COUNT(*) FROM leases WHERE %s),
		(SELECT COUNT(*) FROM events WHERE %s),
		(SELECT COUNT(*) FROM subnets),
		(SELECT COUNT(*) FROM hosts),
		(SELECT COUNT(*) FROM leases),
		(SELECT COUNT(*) FROM events),
		(SELECT COALESCE(MAX(id), 0) FROM events),
		(SELECT COALESCE(MAX(CASE WHEN COALESCE(last_seen, '') > COALESCE(updated_at, '') THEN last_seen ELSE updated_at END), '') FROM hosts),
		(SELECT COALESCE(MAX(updated_at), '') FROM subnets),
		(SELECT COALESCE(MAX(updated_at), '') FROM leases),
		(SELECT COALESCE(MAX(updated_at), '') FROM (
			SELECT CASE WHEN COALESCE(last_seen, '') > COALESCE(updated_at, '') THEN last_seen ELSE updated_at END AS updated_at FROM hosts
			UNION ALL SELECT updated_at FROM subnets
			UNION ALL SELECT updated_at FROM leases
		));]],
		selected_subnet_scope_condition(),
		selected_subnet_exists_for_host(),
		selected_subnet_exists_for_lease(),
		selected_subnet_exists_for_event()),
		{
			"scope_subnets", "scope_hosts", "scope_leases", "scope_events",
			"full_subnets", "full_hosts", "full_leases", "full_events",
			"last_event_id", "last_hosts_updated_at", "last_subnets_updated_at", "last_leases_updated_at", "db_last_write_at"
		},
		{
			scope_subnets = true, scope_hosts = true, scope_leases = true, scope_events = true,
			full_subnets = true, full_hosts = true, full_leases = true, full_events = true,
			last_event_id = true
		})
	local row = rows[1] or {}
	return {
		counts = {
			subnets = row.scope_subnets or 0,
			hosts = row.scope_hosts or 0,
			leases = row.scope_leases or 0,
			events = row.scope_events or 0,
			scope = {
				subnets = row.scope_subnets or 0,
				hosts = row.scope_hosts or 0,
				leases = row.scope_leases or 0,
				events = row.scope_events or 0
			},
			full = {
				subnets = row.full_subnets or 0,
				hosts = row.full_hosts or 0,
				leases = row.full_leases or 0,
				events = row.full_events or 0
			}
		},
		latest = {
			last_event_id = row.last_event_id or 0,
			last_hosts_updated_at = row.last_hosts_updated_at or "",
			last_subnets_updated_at = row.last_subnets_updated_at or "",
			last_leases_updated_at = row.last_leases_updated_at or "",
			db_last_write_at = row.db_last_write_at or ""
		}
	}
end

local function table_counts(config)
	return overview_metrics(config).counts
end

local function read_schema_version(config)
	local meta_raw
	local meta

	if config.meta_path == "" or not fs.access(config.meta_path) then
		return 1
	end

	meta_raw = fs.readfile(config.meta_path)
	if not meta_raw or meta_raw == "" then
		return 1
	end

	meta = jsonc.parse(meta_raw)
	if type(meta) ~= "table" then
		return 1
	end

	return tonumber(meta.schema_version) or 1
end

local function read_meta(config)
	local meta_raw
	local meta
	if config.meta_path == "" or not fs.access(config.meta_path) then
		return {}
	end
	meta_raw = fs.readfile(config.meta_path)
	if not meta_raw or meta_raw == "" then
		return {}
	end
	meta = jsonc.parse(meta_raw)
	if type(meta) ~= "table" then
		return {}
	end
	return meta
end

local function read_status_file(config, name)
	local path
	local raw
	local parsed
	local issue = storage_issue(config)
	if issue then
		return { ok = false, name = name, message = issue }
	end
	if config.status_dir == "" then
		return { ok = false, name = name, message = "status directory unavailable" }
	end
	path = config.status_dir .. "/" .. name .. ".json"
	if not fs.access(path) then
		return { ok = false, name = name, message = "no status recorded" }
	end
	raw = fs.readfile(path)
	if not raw or raw == "" then
		return { ok = false, name = name, message = "status file unreadable" }
	end
	parsed = jsonc.parse(raw)
	if type(parsed) ~= "table" then
		return { ok = false, name = name, message = "status file parse failed" }
	end
	if parsed.name == nil then
		parsed.name = name
	end
	return parsed

end

local function overview_summary_cache_path(config)
	if not config.status_dir or config.status_dir == "" then
		return nil
	end
	return config.status_dir .. "/overview-summary.json"
end

local function read_overview_summary_cache(config)
	local path = overview_summary_cache_path(config)
	local raw
	local payload
	local cached_at
	if not path or not fs.access(path) then
		return nil
	end
	raw = fs.readfile(path)
	if not raw or raw == "" then
		return nil
	end
	payload = jsonc.parse(raw)
	if type(payload) ~= "table" then
		return nil
	end
	cached_at = tonumber(payload.cached_at) or 0
	if cached_at <= 0 or (os.time() - cached_at) > overview_summary_cache_ttl then
		return nil
	end
	return payload.data
end

local function write_overview_summary_cache(config, data)
	local path = overview_summary_cache_path(config)
	local payload
	if not path or not config.status_dir or config.status_dir == "" then
		return
	end
	if not fs.access(config.status_dir) then
		return
	end
	payload = jsonc.stringify({ cached_at = os.time(), data = data }, true)
	if payload and payload ~= "" then
		fs.writefile(path, payload)
	end
end

local function exec_ctl(config, command)
	local output
	if not fs.access(config.ctl_path) then
		return nil
	end
	output = sys.exec(string.format("%s %s 2>/dev/null", shellquote(config.ctl_path), shellquote(command)))
	if not output then
		return nil
	end
	output = output:gsub("%s+$", "")
	return output ~= "" and output or nil
end

local function run_ctl_command(config, command)
	local command_line
	local probe
	local status_line
	local output
	local status
	if not fs.access(config.ctl_path) then
		return { ok = false, status = 127, output = "ctl path unavailable" }
	end
	command_line = string.format("%s %s", shellquote(config.ctl_path), shellquote(command))
	probe = sys.exec(string.format("__lite_ipam_status=0; __lite_ipam_output=$(%s 2>&1) || __lite_ipam_status=$?; printf '__LITE_IPAM_STATUS__=%%s\\n' \"$__lite_ipam_status\"; printf '%%s' \"$__lite_ipam_output\"", command_line))
	status_line, output = tostring(probe or ""):match("^([^\n]*)\n?(.*)$")
	status = tonumber((status_line or ""):match("__LITE_IPAM_STATUS__=(%d+)")) or 1
	output = trim(output)
	return {
		ok = status == 0,
		status = status,
		output = output
	}
end

local function exec_ctl_args(config, args)
	local parts = { shellquote(config.ctl_path) }
	local output
	if not fs.access(config.ctl_path) then
		return nil
	end
	for _, arg in ipairs(args) do
		parts[#parts + 1] = shellquote(arg)
	end
	output = sys.exec(table.concat(parts, " ") .. " 2>/dev/null")
	if not output then
		return nil
	end
	output = output:gsub("%s+$", "")
	return output ~= "" and output or nil
end

local function export_path(config, path)
	local prefix
	if not path or path == "" or config.export_dir == "" then
		return nil
	end
	prefix = config.export_dir .. "/"
	if path:sub(1, #prefix) ~= prefix then
		return nil
	end
	return path
end

local function parse_key_value_output(output)
	local result = { ok = false }
	if not output or output == "" then
		result.error = "command failed"
		return result
	end
	for line in output:gmatch("[^\n]+") do
		local key, value = line:match("^([%w_]+)=(.*)$")
		if key then
			result[key] = value
		end
	end
	result.ok = result.host_id ~= nil or result.action ~= nil
	if not result.ok then
		result.error = "command returned no structured result"
	end
	return result
end

local function lease_refresh_guard_path(config)
	if not config or config.status_dir == "" then
		return nil
	end
	return config.status_dir .. "/lease-sync.guard"
end

local function recent_lease_refresh_exists(config, now_epoch)
	local guard_path = lease_refresh_guard_path(config)
	local recorded_at
	if not guard_path or not fs.access(guard_path) then
		return false
	end
	recorded_at = tonumber(trim(fs.readfile(guard_path) or ""))
	if not recorded_at then
		return false
	end
	return (now_epoch - recorded_at) < lease_refresh_min_interval
end

local function mark_lease_refresh(config, now_epoch)
	local guard_path = lease_refresh_guard_path(config)
	if not guard_path then
		return
	end
	fs.writefile(guard_path, tostring(now_epoch))
end

local function run_lease_refresh(config, force)
	local now_epoch = os.time()
	local result
	if not force and not auto_refresh_enabled then
		return { ok = true, skipped = true, message = "auto refresh disabled" }
	end
	if not force and recent_lease_refresh_exists(config, now_epoch) then
		return { ok = true, skipped = true, message = "lease data is already fresh" }
	end
	local command = run_ctl_command(config, "lease-sync")
	result = command.ok and parse_key_value_output(command.output) or nil
	if result and result.ok then
		mark_lease_refresh(config, os.time())
		return result
	end
	return enrich_command_error(config, "lease-sync", "lease sync failed")
end

local function refresh_leases_from_system(config)
	run_lease_refresh(config, false)
end

enrich_command_error = function(config, status_name, fallback)
	local status = read_status_file(config, status_name)
	if type(status) == "table" then
		local detail = trim(status.detail)
		status.ok = false
		if detail ~= "" then
			status.message = trim(status.message) ~= "" and (status.message .. ": " .. detail) or detail
		end
		if not status.error then
			status.error = status.message or fallback or "command failed"
		end
		return status
	end
	return { ok = false, error = fallback or "command failed" }
end

local function parse_subnet_preview_output(output)
	local result = { ok = true, rows = {}, preview_count = 0, interfaces = "" }
	if not output or output == "" then
		result.ok = false
		result.error = "no preview data returned"
		return result
	end
	for line in output:gmatch("[^\n]+") do
		local row_value = line:match("^row=(.*)$")
		if row_value then
			local fields = {}
			local start_index = 1
			local row_length = #row_value
			for index = 1, row_length + 1 do
				if index > row_length or row_value:sub(index, index) == "|" then
					fields[#fields + 1] = row_value:sub(start_index, index - 1)
					start_index = index + 1
				end
			end
			result.rows[#result.rows + 1] = {
				interface_name = fields[1] or "",
				vlan_id = tonumber(fields[2]) or 0,
				cidr = fields[3] or "",
				gateway = fields[4] or "",
				dns1 = fields[5] or "",
				dns2 = fields[6] or "",
				range_start = fields[7] or "",
				range_end = fields[8] or "",
				lease_time = fields[9] or "",
				enabled = tonumber(fields[10]) or 0,
				device_name = fields[11] or ""
			}
		else
			local key, value = line:match("^([%w_]+)=(.*)$")
			if key == "preview_count" then
				result.preview_count = tonumber(value) or 0
			elseif key == "interfaces" then
				result.interfaces = value or ""
			elseif key == "message" then
				result.message = value or ""
			elseif key == "error" then
				result.ok = false
				result.error = value or "subnet preview failed"
			end
		end
	end
	if #result.rows == 0 and result.preview_count == 0 and not result.message then
		result.message = "no preview rows"
	end
	return result
end

local function latest_timestamps(config)
	return overview_metrics(config).latest
end

local function build_health_payload(config, storage, generation, hook, backup, cleanup, export_state)
	local sqlite_ok = sqlite_available()
	local warnings = {}
	local hard_failures = {}
	local issues = {}
	local notices = {}
	local history = {}
	local publication = read_status_file(config, "publication")
	local lease_sync = read_status_file(config, "lease-sync")
	local worker = read_status_file(config, "worker")
	local database = read_status_file(config, "database")
	local worker_pid = tonumber(worker.pid)
	local worker_running = worker_pid and worker_pid > 0
		and sys.call("kill -0 " .. tostring(worker_pid) .. " 2>/dev/null") == 0 or false
	local expected_hook = "/usr/libexec/lite-ipam/dnsmasq-lease-hook.sh"
	local expected_hotplug = "/etc/hotplug.d/dhcp/90-lite-ipam"
	local expected_hostsfile = config.hosts_dir or ""
	local current_hook = uci:get_first("dhcp", "dnsmasq", "dhcpscript") or ""
	local current_hostsfile = uci:get_first("dhcp", "dnsmasq", "dhcphostsfile") or ""
	local dnsmasq_sections = {}
	local target_sections = resolve_target_dnsmasq_sections()
	local dnsmasq_hook_map = {}
	local mismatched_sections = {}
	local dnsmasq_hostsfile_map = {}
	local mismatched_hostsfile_sections = {}
	local hotplug_exists = fs.access(expected_hotplug) and true or false
	local hook_runtime = {
		observed = false,
		matched = false,
		last_event_at = "",
		action = "",
		interface_name = "",
		host_created = false,
		message = config.enabled and #target_sections > 0 and "尚未观察到租约 Hook 事件" or "当前未启用 Hook 运行观测"
	}
	local function is_missing_status(status)
		return type(status) == "table" and status.ok == false and status.message == "no status recorded"
	end
	local function add_issue(code, severity, title, impact, action, status, target)
		local detail = status and tostring(status.detail or status.message or "") or ""
		local reason = "具体原因尚未确认，请查看技术详情和日志。"
		if detail == "no status recorded" then
			reason = "尚无运行记录，不能据此认定执行失败。"
		elseif detail == "data_root is not configured" then
			reason = "尚未配置数据目录。"
		elseif detail == "data_root does not exist" then
			reason = "数据目录不存在，可能是数据盘未挂载或路径配置有误。"
		elseif detail:find("timed out acquiring", 1, true) then
			reason = "等待操作锁超时，可能有其他任务正在占用。"
		elseif detail:find("validation failed", 1, true) then
			reason = "绑定内容未通过校验，旧文件已保留。"
		elseif detail:find("load not verified", 1, true) then
			reason = "未观察到目标 dnsmasq 确认读取绑定文件。"
		elseif detail:find("sqlite", 1, true) then
			reason = "数据库操作失败，具体 SQL 错误请查看技术详情或日志。"
		elseif detail:find("parse failed", 1, true) or detail:find("unreadable", 1, true) then
			reason = "状态记录无法读取或解析，不能确认该项目是否正常。"
		end
		local item = {
			code = code, severity = severity, title = title, impact = impact,
			action = action, target = target or "logs",
			at = status and status.updated_at or "",
			reason = status and reason or "", detail = detail
		}
		issues[#issues + 1] = item
		if severity == "error" then
			hard_failures[#hard_failures + 1] = title
		else
			warnings[#warnings + 1] = title
		end
	end
	local function check_status(name, status, label, impact, action, target, optional)
		if type(status) ~= "table" then
			return
		end
		local failure_path = config.status_dir .. "/" .. name .. ".last-failure.json"
		local failure = fs.access(failure_path) and read_status_file(config, name .. ".last-failure") or nil
		if failure and (failure.ok ~= false or not failure.updated_at) then
			add_issue(name .. "-history", "warning", label .. "历史记录无效",
				"无法确认上次失败详情。", "查看日志，检查状态文件。", failure)
		elseif failure and status.ok == true then
			local recovery = read_status_file(config, name .. ".recovery")
			history[#history + 1] = {
				code = name, title = label .. (recovery.ok == true and "已恢复" or "最近一次执行成功"),
				at = failure.updated_at or "", recovered_at = recovery.ok == true and recovery.updated_at or "",
				detail = failure.detail or failure.message or "", severity = "recovered"
			}
		end
		if is_missing_status(status) then
			notices[#notices + 1] = { code = name, title = label .. "尚未执行", severity = "info" }
			if not optional and config.enabled then
				add_issue(name, "warning", label .. "尚未验证", impact, action, status, target)
			end
		elseif status.ok ~= true and config.enabled then
			add_issue(name, optional and "warning" or "error", label .. "最近一次执行失败",
				impact, action, status, target)
		end
	end

	check_status("generation", generation, "绑定文件生成", "最新绑定可能尚未生成，不能确认最新配置已生效。",
		"检查主机 MAC/IP 冲突及日志；修正后执行 lite-ipamctl apply-dnsmasq。", "logs")
	check_status("hook", hook, "租约 Hook", "上次事件写入失败；后台对账可补齐快照，但不能据此确认 Hook 已恢复。",
		"查看错误详情；等待下一次自然租约事件验证。", "logs", true)
	check_status("backup", backup, "备份", "最近一次备份未完成，不影响当前 DHCP；请确认有可用备份。",
		"检查备份策略、空间和权限，通过 lite-ipamctl backup-now 重试。", "settings", true)
	check_status("cleanup", cleanup, "历史清理", "最近一次历史清理未完成，不影响当前 DHCP。",
		"检查保留策略及空间，通过 lite-ipamctl cleanup-runtime 重试；会按策略删除历史记录。", "settings", true)
	check_status("export", export_state, "数据导出", "最近一次导出未完成，不影响当前 DHCP。",
		"查看日志，检查导出目录后重试。", "logs", true)
	check_status("publication", publication, "固定绑定发布", "尚未确认 dnsmasq 加载最新绑定；是否回退成功请查看日志。",
		"后台对待发布变更自动重试；持续失败时检查日志，通过 lite-ipamctl apply-dnsmasq 重试。", "logs")
	check_status("lease-sync", lease_sync, "租约对账", "数据库中的有效租约可能不是最新快照。",
		"后台会周期重试，也可点击“同步租约”立即重试。", "leases")
	if config.enabled and not worker_running then
		add_issue("worker", "error", "后台对账进程未运行", "自动租约对账和合并发布无法继续。",
			"检查服务日志后重启 lite-ipam 服务。", worker)
	end
	if tonumber(database.failures) and tonumber(database.failures) > 0 then
		history[#history + 1] = {
			code = "database", title = "数据库历史失败 " .. tostring(database.failures) .. " 次",
			at = database.updated_at or "", detail = database.detail or database.message or "",
			severity = "info", impact = "累计值不代表当前数据库故障；最近一次操作是否恢复需结合对账和 Hook 状态判断。"
		}
	end
	uci:foreach("dhcp", "dnsmasq", function(section)
		dnsmasq_sections[#dnsmasq_sections + 1] = tostring(section[".name"] or "")
	end)
	for _, section_name in ipairs(target_sections) do
		local section_hook = tostring(uci:get("dhcp", section_name, "dhcpscript") or "")
		local section_hostsfile = tostring(uci:get("dhcp", section_name, "dhcphostsfile") or "")
		dnsmasq_hook_map[section_name] = section_hook
		dnsmasq_hostsfile_map[section_name] = section_hostsfile
		if config.enabled and section_hook ~= expected_hook then
			mismatched_sections[#mismatched_sections + 1] = section_name
		end
		if config.enabled and expected_hostsfile ~= "" and section_hostsfile ~= expected_hostsfile then
			mismatched_hostsfile_sections[#mismatched_hostsfile_sections + 1] = section_name
		end
	end
	if type(hook) == "table" and hook.updated_at and hook.updated_at ~= "" and not is_missing_status(hook) then
		hook_runtime.observed = true
		hook_runtime.matched = hook.matched == true
		hook_runtime.last_event_at = tostring(hook.updated_at or "")
		hook_runtime.action = tostring(hook.action or "")
		hook_runtime.interface_name = tostring(hook.interface or "")
		hook_runtime.host_created = hook.host_created == true
		if hook.ok == false then
			hook_runtime.message = tostring(hook.message or "最近一次租约 Hook 事件失败")
		elseif hook_runtime.matched then
			hook_runtime.message = "最近一次租约 Hook 事件已记录"
		elseif hook.ok == true then
			hook_runtime.message = tostring(hook.message or "最近一次事件未命中当前纳管接口")
		else
			hook_runtime.message = tostring(hook.message or "最近一次租约 Hook 事件失败")
		end
	end

	if not storage.ok then
		add_issue("storage", "error", "数据存储不可用", "无法可靠读取或保存 IPAM 数据。",
			"检查数据盘挂载、可用空间和目录写入权限。", storage, "settings")
	end
	if not sqlite_ok then
		add_issue("sqlite", "error", "SQLite 程序不可用", "无法读取和更新数据库。",
			"检查 sqlite3-cli 软件包是否安装。")
	end
	if config.enabled and not hotplug_exists then
		add_issue("hotplug", "error", "DHCP 事件处理脚本缺失", "租约事件不能正常进入 IPAM。",
			"重新安装 lite-ipam 软件包。")
	end
	if config.enabled and #target_sections == 0 then
		add_issue("dnsmasq", "error", "未找到目标 dnsmasq 实例", "无法接入 DHCP 租约和固定绑定。",
			"检查 DHCP 实例及纳管接口设置。", nil, "settings")
	elseif config.enabled and #mismatched_sections > 0 then
		add_issue("dhcpscript", "error", "租约 Hook 配置不匹配", "目标实例：" .. table.concat(mismatched_sections, "、"),
			"在设置页重新应用 dnsmasq 接入配置。", nil, "settings")
	end
	if config.enabled and expected_hostsfile ~= "" and #mismatched_hostsfile_sections > 0 then
		add_issue("hostsfile", "error", "固定绑定目录配置不匹配", "目标实例：" .. table.concat(mismatched_hostsfile_sections, "、"),
			"在设置页重新应用 dnsmasq 接入配置。", nil, "settings")
	end

	local publication_pending = fs.access(config.data_root .. "/tmp/hosts.dirty") and true or false
	if config.enabled and publication_pending then
		notices[#notices + 1] = { code = "pending", severity = "pending", title = "固定绑定有待发布变更",
			impact = "最新变更尚未确认生效。", action = "后台会合并发布；失败时退避重试，无需反复点击。"}
	end
	local level = not config.enabled and "disabled" or (#hard_failures > 0 and "error"
		or (#warnings > 0 and "warning" or (publication_pending and "pending" or "ok")))
	table.sort(issues, function(a, b)
		if a.severity ~= b.severity then return a.severity == "error" end
		return a.code < b.code
	end)
	local message = level == "disabled" and "服务已禁用，不执行自动对账与发布"
		or (#issues > 0 and issues[1].title
		or (publication_pending and "固定绑定变更等待后台发布" or "后台检查通过，无待发布变更"))
	return {
		ok = config.enabled and #hard_failures == 0,
		enabled = config.enabled,
		level = level,
		message = message,
		issues = issues,
		notices = notices,
		history = history,
		warnings = warnings,
		sqlite_available = sqlite_ok,
		storage = storage,
		dnsmasq_hostsfile = current_hostsfile,
		dnsmasq_dhcpscript = current_hook,
		expected_hostsfile = expected_hostsfile,
		expected_dhcpscript = expected_hook,
		dhcp_hotplug_script = expected_hotplug,
		dhcp_hotplug_exists = hotplug_exists,
		dnsmasq_sections = dnsmasq_sections,
		dnsmasq_target_sections = target_sections,
		dnsmasq_section_hooks = dnsmasq_hook_map,
		dnsmasq_mismatched_sections = mismatched_sections,
		dnsmasq_section_hostsfiles = dnsmasq_hostsfile_map,
		dnsmasq_hostsfile_mismatched_sections = mismatched_hostsfile_sections,
		generation = generation,
		publication = publication,
		lease_sync = lease_sync,
		worker = worker,
		worker_running = worker_running,
		publication_pending = publication_pending,
		database = database,
		hook = hook,
		hook_runtime = hook_runtime,
		backup = backup,
		cleanup = cleanup,
		export = export_state
	}
end

function M.get_storage_status()
	local config = load_config()
	local data_root_writable = false
	local issue = storage_issue(config)
	if config.data_root ~= "" then
		data_root_writable = file_writable(config.data_root .. "/.write-test")
	end

	return {
		ok = issue == nil,
		message = issue or "storage ready",
		configured = config.data_root ~= "",
		data_root = config.data_root,
		data_root_exists = config.data_root ~= "" and fs.access(config.data_root) or false,
		data_root_writable = data_root_writable,
		db_path = config.db_path,
		db_exists = db_ready(config),
		hosts_conf_path = config.hosts_conf_path,
		hosts_conf_exists = config.hosts_conf_path ~= "" and fs.access(config.hosts_conf_path) or false,
		meta_path = config.meta_path,
		meta_exists = config.meta_path ~= "" and fs.access(config.meta_path) or false,
		log_path = config.log_path,
		log_exists = config.log_path ~= "" and fs.access(config.log_path) or false,
		status_dir = config.status_dir,
		status_dir_exists = config.status_dir ~= "" and fs.access(config.status_dir) or false
	}
end

function M.get_recent_logs(limit, source)
	local config = load_config()
	local line_limit = tonumber(limit) or 50
	local command
	local rows = {}
	source = trim(source)
	if source == "" then
		source = "system"
	end
	if line_limit < 1 then
		line_limit = 50
	end
	if line_limit > 200 then
		line_limit = 200
	end
	if source == "runtime" then
		if config.log_path ~= "" and fs.access(config.log_path) then
			command = string.format("tail -n %d %s 2>/dev/null", line_limit, shellquote(config.log_path))
			for line in util.execi(command) do
				rows[#rows + 1] = line:gsub("%s+$", "")
			end
			return {
				ok = true,
				source = "runtime",
				path = config.log_path,
				rows = rows,
				message = "using runtime log"
			}
		end
		return {
			ok = false,
			source = "runtime",
			path = config.log_path ~= "" and config.log_path or "runtime.log",
			rows = {},
			message = "runtime log is unavailable"
		}
	end
	command = string.format("logread 2>/dev/null | grep -i %s | tail -n %d", shellquote("lite-ipam"), line_limit)
	for line in util.execi(command) do
		rows[#rows + 1] = line:gsub("%s+$", "")
	end
	return {
		ok = #rows > 0,
		source = "system",
		path = "logread",
		rows = rows,
		message = #rows > 0 and "using system log" or "no recent logs found in system log"
	}
end

function M.get_backup_status()
	local config = load_config()
	return read_status_file(config, "backup")
end

function M.get_cleanup_status()
	local config = load_config()
	return read_status_file(config, "cleanup")
end

function M.get_health()
	local config = load_config()
	local storage = M.get_storage_status()
	local generation = read_status_file(config, "generation")
	local hook = read_status_file(config, "hook")
	local backup = read_status_file(config, "backup")
	local cleanup = read_status_file(config, "cleanup")
	local export_state = read_status_file(config, "export")
	return build_health_payload(config, storage, generation, hook, backup, cleanup, export_state)
end

function M.get_status()
	local config = load_config()
	local meta = read_meta(config)
	local latest = latest_timestamps(config)
	local issue = storage_issue(config)

	return {
		app = "lite-ipam",
		api_version = "v1",
		enabled = config.enabled,
		configured = config.data_root ~= "",
		message = issue or "ready",
		node_id = meta.node_id or "",
		node_name = config.node_name,
		data_root = config.data_root,
		db_path = config.db_path,
		hosts_conf_path = config.hosts_conf_path,
		schema_version = read_schema_version(config),
		last = latest,
		backup = read_status_file(config, "backup"),
		cleanup = read_status_file(config, "cleanup"),
		counts = table_counts(config)
	}
end

function M.get_sync_cursor()
	local config = load_config()
	local meta = read_meta(config)
	local latest = latest_timestamps(config)

	return {
		ok = true,
		app = "lite-ipam",
		api_version = "v1",
		node_id = meta.node_id or "",
		node_name = config.node_name,
		cursor = latest,
		counts = table_counts(config)
	}
end

function M.get_sync_batch(filters)
	local config = load_config()
	local meta = read_meta(config)
	local default_limit, max_limit = api_page_limits(100, 500)
	local limit = tonumber(filters.limit) or default_limit
	if limit < 1 then
		limit = default_limit
	end
	if limit > max_limit then
		limit = max_limit
	end

	return {
		ok = true,
		app = "lite-ipam",
		api_version = "v1",
		node_id = meta.node_id or "",
		node_name = config.node_name,
		requested = {
			hosts_since = filters.hosts_since or "",
			subnets_since = filters.subnets_since or "",
			leases_since = filters.leases_since or "",
			events_after_id = tonumber(filters.events_after_id) or 0,
			limit = limit
		},
		data = {
			hosts = M.list_hosts_changed(filters.hosts_since or "", limit),
			subnets = M.list_subnets_changed(filters.subnets_since or "", limit),
			leases = M.list_leases_changed(filters.leases_since or "", limit),
			events = M.list_events_since(tonumber(filters.events_after_id) or 0, limit)
		},
		cursor = latest_timestamps(config),
		counts = table_counts(config)
	}
end

function M.get_settings()
	return {
		core = {
			enabled = typed_get("core", "enabled", "1"),
			node_name = typed_get("core", "node_name", ""),
			data_root = typed_get("core", "data_root", ""),
			auto_init = typed_get("core", "auto_init", "1"),
			auto_create_subdirs = typed_get("core", "auto_create_subdirs", "1"),
			backup_retention_days = typed_get("core", "backup_retention_days", "30"),
			apply_mode = typed_get("core", "apply_mode", "immediate")
		},
		api = {
			enabled = typed_get("api", "enabled", "0"),
			read_token = typed_get("api", "read_token", ""),
			write_token = typed_get("api", "write_token", ""),
			max_page_size = typed_get("api", "max_page_size", "500"),
			default_page_size = typed_get("api", "default_page_size", "100")
		},
		backup = {
			enabled = typed_get("backup", "enabled", "1"),
			cron_enabled = typed_get("backup", "cron_enabled", "1"),
			cron_schedule = typed_get("backup", "cron_schedule", "0 3 * * *"),
			mail_enabled = typed_get("backup", "mail_enabled", "0"),
			mail_from = typed_get("backup", "mail_from", ""),
			mail_to = typed_get("backup", "mail_to", ""),
			smtp_host = typed_get("backup", "smtp_host", ""),
			smtp_port = typed_get("backup", "smtp_port", "587"),
			smtp_user = typed_get("backup", "smtp_user", ""),
			smtp_password = typed_get("backup", "smtp_password", ""),
			smtp_tls = typed_get("backup", "smtp_tls", "1")
		},
		maintenance = {
			enabled = typed_get("maintenance", "enabled", "1"),
			lease_retention_days = typed_get("maintenance", "lease_retention_days", "90"),
			event_retention_days = typed_get("maintenance", "event_retention_days", "180"),
			vacuum_after_cleanup = typed_get("maintenance", "vacuum_after_cleanup", "1")
		}
	}
end

function M.save_settings(settings)
	local ok = true
	local storage
	local init_result = { attempted = false, needed = false }
	local integration_result = { attempted = false, needed = false }
	local failed = {}
	local data_root = trim(settings.core_data_root)
	local data_root_error = validate_data_root_for_save(settings.core_data_root, settings.core_enabled)
	local function stage(type_name, option_name, value, request_key)
		local stage_ok, stage_error = typed_set(type_name, option_name, value)
		ok = stage_ok and ok
		if not stage_ok then
			failed[#failed + 1] = {
				key = request_key,
				option = type_name .. "." .. option_name,
				error = stage_error or "unknown error"
			}
		end
	end

	if data_root_error then
		return {
			ok = false,
			error = "invalid data_root",
			failed = {
				{
					key = "core_data_root",
					option = "core.data_root",
					error = data_root_error
				}
			}
		}
	end

	stage("core", "enabled", settings.core_enabled, "core_enabled")
	stage("core", "node_name", settings.core_node_name, "core_node_name")
	stage("core", "data_root", data_root, "core_data_root")
	stage("core", "auto_init", settings.core_auto_init, "core_auto_init")
	stage("core", "auto_create_subdirs", settings.core_auto_create_subdirs, "core_auto_create_subdirs")
	stage("core", "backup_retention_days", settings.core_backup_retention_days, "core_backup_retention_days")
	stage("core", "apply_mode", settings.core_apply_mode, "core_apply_mode")
	stage("api", "enabled", settings.api_enabled, "api_enabled")
	stage("api", "read_token", settings.api_read_token, "api_read_token")
	stage("api", "write_token", settings.api_write_token, "api_write_token")
	stage("api", "max_page_size", settings.api_max_page_size, "api_max_page_size")
	stage("api", "default_page_size", settings.api_default_page_size, "api_default_page_size")
	stage("backup", "enabled", settings.backup_enabled, "backup_enabled")
	stage("backup", "cron_enabled", settings.backup_cron_enabled, "backup_cron_enabled")
	stage("backup", "cron_schedule", settings.backup_cron_schedule, "backup_cron_schedule")
	stage("backup", "mail_enabled", settings.backup_mail_enabled, "backup_mail_enabled")
	stage("backup", "mail_from", settings.backup_mail_from, "backup_mail_from")
	stage("backup", "mail_to", settings.backup_mail_to, "backup_mail_to")
	stage("backup", "smtp_host", settings.backup_smtp_host, "backup_smtp_host")
	stage("backup", "smtp_port", settings.backup_smtp_port, "backup_smtp_port")
	stage("backup", "smtp_user", settings.backup_smtp_user, "backup_smtp_user")
	stage("backup", "smtp_password", settings.backup_smtp_password, "backup_smtp_password")
	stage("backup", "smtp_tls", settings.backup_smtp_tls, "backup_smtp_tls")
	stage("maintenance", "enabled", settings.maintenance_enabled, "maintenance_enabled")
	stage("maintenance", "lease_retention_days", settings.maintenance_lease_retention_days, "maintenance_lease_retention_days")
	stage("maintenance", "event_retention_days", settings.maintenance_event_retention_days, "maintenance_event_retention_days")
	stage("maintenance", "vacuum_after_cleanup", settings.maintenance_vacuum_after_cleanup, "maintenance_vacuum_after_cleanup")
	if not ok then
		return {
			ok = false,
			error = "failed to stage settings",
			failed = failed
		}
	end
	if not uci:commit("lite-ipam") then
		return {
			ok = false,
			error = "failed to commit settings"
		}
	end
	local config = load_config()
	if config.data_root ~= "" and (not fs.access(config.db_path) or not fs.access(config.meta_path)) then
		local init_command, init_probe, init_status_line, init_output, init_status
		init_result.attempted = true
		init_result.needed = true
		init_result.reason = (not fs.access(config.db_path) and "database missing" or "metadata missing")
		init_result.trigger = init_result.reason
		init_command = string.format("%s %s", shellquote(config.ctl_path), shellquote("init-service"))
		init_probe = sys.exec(string.format("__lite_ipam_status=0; __lite_ipam_output=$(%s 2>&1) || __lite_ipam_status=$?; printf '__LITE_IPAM_STATUS__=%%s\\n' \"$__lite_ipam_status\"; printf '%%s' \"$__lite_ipam_output\"", init_command))
		init_status_line, init_output = tostring(init_probe or ""):match("^([^\n]*)\n?(.*)$")
		init_status = tonumber((init_status_line or ""):match("__LITE_IPAM_STATUS__=(%d+)")) or 1
		init_result.ok = init_status == 0
		init_output = trim(init_output)
		if init_output ~= "" then
			init_result.detail = init_output
		end
		init_result.message = init_result.ok and "storage initialized" or "storage initialization failed"
		config = load_config()
	end
	integration_result.needed = config.enabled and config.data_root ~= ""
	if integration_result.needed then
		local apply_dnsmasq_result
		local apply_hook_result
		integration_result.attempted = true
		apply_dnsmasq_result = run_ctl_command(config, "apply-dnsmasq")
		apply_hook_result = run_ctl_command(config, "apply-hook")
		integration_result.dnsmasq = {
			ok = apply_dnsmasq_result.ok,
			message = apply_dnsmasq_result.ok and "dnsmasq hosts integration applied" or (apply_dnsmasq_result.output ~= "" and apply_dnsmasq_result.output or "apply-dnsmasq failed"),
			status = read_status_file(config, "generation")
		}
		integration_result.hook = {
			ok = apply_hook_result.ok,
			message = apply_hook_result.ok and "dnsmasq lease hook applied" or (apply_hook_result.output ~= "" and apply_hook_result.output or "apply-hook failed"),
			status = read_status_file(config, "hook")
		}
	end
	sys.call(string.format("%s %s >/dev/null 2>&1", shellquote(config.ctl_path), shellquote("ensure-cron")))
	storage = M.get_storage_status()
	local message
	if not storage.ok then
		message = "settings saved but storage check failed: " .. (storage.message or "unknown error")
	elseif integration_result.attempted and integration_result.dnsmasq and not integration_result.dnsmasq.ok then
		message = "settings saved but dnsmasq hosts integration failed"
	elseif integration_result.attempted and integration_result.hook and not integration_result.hook.ok then
		message = "settings saved but dnsmasq lease hook integration failed"
	elseif init_result.ok then
		message = "settings saved and storage initialized"
	elseif integration_result.attempted then
		message = "settings saved and dnsmasq integration refreshed"
	else
		message = "settings saved and storage is ready"
	end
	return {
		ok = true,
		action = "settings_save",
		initialization = init_result,
		integration = integration_result,
		validation = storage,
		message = message
	}
end

function M.get_host(host_id)
	local config = load_config()
	local rows
	if not host_id then
		return {}
	end
	rows = query_rows(config, string.format([[SELECT
		id,
		COALESCE(hostname, ''),
		COALESCE(mac, ''),
		COALESCE(ip, ''),
		COALESCE(subnet_id, 0),
		COALESCE(vlan_id, 0),
		COALESCE(type, ''),
		COALESCE(owner, ''),
		COALESCE(comment, ''),
		COALESCE(reserved, 0),
		COALESCE(enabled, 0),
		COALESCE(source, ''),
		COALESCE(reservation_type, ''),
		COALESCE(sync_status, ''),
		COALESCE(created_at, ''),
		COALESCE(updated_at, ''),
		COALESCE(last_seen, '')
	FROM hosts
	WHERE id = %d AND %s
	LIMIT 1;]], host_id, selected_subnet_exists_for_host()),
		{"id", "hostname", "mac", "ip", "subnet_id", "vlan_id", "type", "owner", "comment", "reserved", "enabled", "source", "reservation_type", "sync_status", "created_at", "updated_at", "last_seen"},
		{id = true, subnet_id = true, vlan_id = true, reserved = true, enabled = true})
	return enrich_host_activity_row(rows[1] or {})
end

function M.list_hosts_changed(since, limit)
	local config = load_config()
	local escaped_since = (since or ""):gsub("'", "''")
	local sql = string.format([[SELECT
		id,
		COALESCE(hostname, ''),
		COALESCE(mac, ''),
		COALESCE(ip, ''),
		COALESCE(subnet_id, 0),
		COALESCE(vlan_id, 0),
		COALESCE(type, ''),
		COALESCE(owner, ''),
		COALESCE(comment, ''),
		COALESCE(reserved, 0),
		COALESCE(enabled, 0),
		COALESCE(source, ''),
		COALESCE(reservation_type, ''),
		COALESCE(sync_status, ''),
		COALESCE(created_at, ''),
		COALESCE(updated_at, ''),
		COALESCE(last_seen, '')
	FROM hosts
	WHERE (updated_at > '%s' OR last_seen > '%s')
	  AND %s
	ORDER BY CASE WHEN COALESCE(last_seen, '') > COALESCE(updated_at, '') THEN last_seen ELSE updated_at END ASC, id ASC
	LIMIT %d;]], escaped_since, escaped_since, selected_subnet_exists_for_host(), limit)
	return enrich_host_activity_rows(query_rows(config, sql,
		{"id", "hostname", "mac", "ip", "subnet_id", "vlan_id", "type", "owner", "comment", "reserved", "enabled", "source", "reservation_type", "sync_status", "created_at", "updated_at", "last_seen"},
		{id = true, subnet_id = true, vlan_id = true, reserved = true, enabled = true}
	))
end

function M.list_hosts(limit)
	local config = load_config()
	local sql = string.format([[SELECT
		id,
		COALESCE(hostname, ''),
		COALESCE(mac, ''),
		COALESCE(ip, ''),
		COALESCE(subnet_id, 0),
		COALESCE(vlan_id, 0),
		COALESCE(type, ''),
		COALESCE(owner, ''),
		COALESCE(comment, ''),
		COALESCE(reserved, 0),
		COALESCE(enabled, 0),
		COALESCE(source, ''),
		COALESCE(reservation_type, ''),
		COALESCE(sync_status, ''),
		COALESCE(created_at, ''),
		COALESCE(updated_at, ''),
		COALESCE(last_seen, '')
	FROM hosts
	WHERE %s
	ORDER BY id ASC
	LIMIT %d;]], selected_subnet_exists_for_host(), limit)
	return enrich_host_activity_rows(query_rows(config, sql,
		{"id", "hostname", "mac", "ip", "subnet_id", "vlan_id", "type", "owner", "comment", "reserved", "enabled", "source", "reservation_type", "sync_status", "created_at", "updated_at", "last_seen"},
		{id = true, subnet_id = true, vlan_id = true, reserved = true, enabled = true}
	))
end

function M.list_recent_hosts(limit)
	local config = load_config()
	local default_limit, max_limit = api_page_limits(10, 50)
	limit = tonumber(limit) or default_limit
	if limit < 1 then
		limit = default_limit
	end
	if limit > max_limit then
		limit = max_limit
	end
	return enrich_host_activity_rows(query_rows(config, string.format([[SELECT
		id,
		COALESCE(hostname, ''),
		COALESCE(ip, ''),
		COALESCE(mac, ''),
		COALESCE(subnet_id, 0),
		COALESCE(vlan_id, 0),
		COALESCE(updated_at, ''),
		COALESCE(last_seen, '')
	FROM hosts
	WHERE %s
	ORDER BY CASE WHEN COALESCE(last_seen, '') > COALESCE(updated_at, '') THEN last_seen ELSE updated_at END DESC, id DESC
	LIMIT %d;]], selected_subnet_exists_for_host(), limit),
		{"id", "hostname", "ip", "mac", "subnet_id", "vlan_id", "updated_at", "last_seen"},
		{id = true, subnet_id = true, vlan_id = true}
	))
end

function M.list_subnets(limit)
	local config = load_config()
	local sql = string.format([[SELECT
		id,
		COALESCE(vlan_id, 0),
		COALESCE(name, ''),
		COALESCE(interface_name, ''),
		COALESCE(cidr, ''),
		COALESCE(gateway, ''),
		COALESCE(dns1, ''),
		COALESCE(dns2, ''),
		COALESCE(range_start, ''),
		COALESCE(range_end, ''),
		COALESCE(lease_time, ''),
		COALESCE(display_name, ''),
		COALESCE(comment, ''),
		COALESCE(source, ''),
		COALESCE(sync_status, ''),
		COALESCE(enabled, 0),
		COALESCE(created_at, ''),
		COALESCE(updated_at, '')
	FROM subnets
	WHERE enabled = 1 AND %s
	ORDER BY id ASC
	LIMIT %d;]], selected_subnet_scope_condition(), limit)

	return query_rows(config, sql,
		{"id", "vlan_id", "name", "interface_name", "cidr", "gateway", "dns1", "dns2", "range_start", "range_end", "lease_time", "display_name", "comment", "source", "sync_status", "enabled", "created_at", "updated_at"},
		{id = true, vlan_id = true, enabled = true}
	)
end

function M.list_subnets_changed(since, limit)
	local config = load_config()
	local escaped_since = (since or ""):gsub("'", "''")
	local sql = string.format([[SELECT
		id,
		COALESCE(vlan_id, 0),
		COALESCE(name, ''),
		COALESCE(interface_name, ''),
		COALESCE(cidr, ''),
		COALESCE(gateway, ''),
		COALESCE(dns1, ''),
		COALESCE(dns2, ''),
		COALESCE(range_start, ''),
		COALESCE(range_end, ''),
		COALESCE(lease_time, ''),
		COALESCE(display_name, ''),
		COALESCE(comment, ''),
		COALESCE(source, ''),
		COALESCE(sync_status, ''),
		COALESCE(enabled, 0),
		COALESCE(created_at, ''),
		COALESCE(updated_at, '')
	FROM subnets
	WHERE updated_at > '%s'
	  AND enabled = 1
	  AND %s
	ORDER BY updated_at ASC, id ASC
	LIMIT %d;]], escaped_since, selected_subnet_scope_condition(), limit)

	return query_rows(config, sql,
		{"id", "vlan_id", "name", "interface_name", "cidr", "gateway", "dns1", "dns2", "range_start", "range_end", "lease_time", "display_name", "comment", "source", "sync_status", "enabled", "created_at", "updated_at"},
		{id = true, vlan_id = true, enabled = true}
	)
end

function M.list_subnet_sync_candidates()
	local candidates = {}
	local selected = selected_sync_interfaces_map()
	local seen = {}
	local function append_candidate(interface_name, attrs)
		local proto
		interface_name = tostring(interface_name or ""):match("^%s*(.-)%s*$")
		if interface_name == "" or seen[interface_name] then
			return
		end
		attrs = attrs or {}
		if tostring(attrs.ignore or "0") == "1" then
			return
		end
		proto = uci:get("network", interface_name, "proto") or ""
		if proto == "dhcp" or proto == "pppoe" or proto == "none" then
			return
		end
		seen[interface_name] = true
		candidates[#candidates + 1] = {
			interface_name = interface_name,
			selected = selected[interface_name] or false,
			ignore = attrs.ignore or "0",
			proto = proto,
			start = attrs.start or "",
			limit = attrs.limit or "",
			lease_time = attrs.lease_time or ""
		}
	end
	uci:foreach("dhcp", "dhcp", function(section)
		append_candidate(section.interface, {
			ignore = section.ignore or "0",
			start = section.start or "",
			limit = section.limit or "",
			lease_time = section.leasetime or ""
		})
	end)
	table.sort(candidates, function(left, right)
		return tostring(left.interface_name or "") < tostring(right.interface_name or "")
	end)
	return candidates
end

function M.get_subnet_sync_selection()
	return {
		ok = true,
		interfaces = map_keys_sorted(selected_sync_interfaces_map())
	}
end

function M.get_overview_summary()
	local config = load_config()
	local cached = read_overview_summary_cache(config)
	local metrics
	local meta
	local issue
	local storage
	local generation
	local hook
	local backup
	local cleanup
	local export_state
	local summary

	if cached then
		return cached
	end

	metrics = overview_metrics(config)
	meta = read_meta(config)
	issue = storage_issue(config)
	storage = M.get_storage_status()
	generation = read_status_file(config, "generation")
	hook = read_status_file(config, "hook")
	backup = read_status_file(config, "backup")
	cleanup = read_status_file(config, "cleanup")
	export_state = read_status_file(config, "export")
	summary = {
		ok = true,
		status = {
			app = "lite-ipam",
			api_version = "v1",
			enabled = config.enabled,
			configured = config.data_root ~= "",
			message = issue or "ready",
			node_id = meta.node_id or "",
			node_name = config.node_name,
			data_root = config.data_root,
			db_path = config.db_path,
			hosts_conf_path = config.hosts_conf_path,
			schema_version = read_schema_version(config),
			last = metrics.latest,
			backup = backup,
			cleanup = cleanup,
			counts = metrics.counts
		},
		health = build_health_payload(config, storage, generation, hook, backup, cleanup, export_state),
		storage = storage,
		backup = backup
	}
	write_overview_summary_cache(config, summary)
	return summary
end

function M.get_overview_summary_uncached()
	local config = load_config()
	local path = overview_summary_cache_path(config)
	if path and fs.access(path) then
		fs.remove(path)
	end
	return M.get_overview_summary()
end

function M.save_subnet_sync_selection(interfaces)
	local normalized = normalize_interface_list(interfaces)
	local expected = table.concat(normalized, " ")
	local auto = {}
	local message
	local ok, err = set_sync_subnet_interfaces(table.concat(normalized, " "))
	if not ok then
		return { ok = false, error = err or "failed to save subnet sync selection" }
	end
	if not uci:commit("lite-ipam") then
		return { ok = false, error = "failed to commit subnet sync selection" }
	end
	local applied_interfaces = map_keys_sorted(selected_sync_interfaces_map())
	local applied = table.concat(applied_interfaces, " ")
	if applied ~= expected then
		return {
			ok = false,
			error = "subnet sync selection verification failed",
			expected_interfaces = normalized,
			applied_interfaces = applied_interfaces
		}
	end
	if #normalized > 0 then
		local config = load_config()
		auto.subnet_sync = M.sync_subnets({ interfaces = normalized })
		auto.lease_hook = parse_key_value_output(exec_ctl(config, "apply-hook"))
	end
	if #normalized == 0 then
		message = "subnet sync selection cleared"
	elseif auto.subnet_sync and auto.subnet_sync.ok and auto.lease_hook and auto.lease_hook.ok then
		message = "subnet sync selection saved; subnet database and lease hook refreshed"
	elseif auto.subnet_sync and auto.subnet_sync.ok then
		message = "subnet sync selection saved; subnet database refreshed, lease hook needs attention"
	else
		message = "subnet sync selection saved; automatic refresh needs attention"
	end
	return {
		ok = true,
		action = "subnet_selection_save",
		interfaces = applied_interfaces,
		auto = auto,
		message = message
	}
end

function M.preview_subnets(options)
	local config = load_config()
	local args = { "subnet-preview" }
	local interfaces = options and options.interfaces or nil
	local existing = {}
	local sql
	local preview
	if type(interfaces) == "table" then
		for _, interface_name in ipairs(interfaces) do
			if interface_name and interface_name ~= "" then
				args[#args + 1] = "--interface"
				args[#args + 1] = interface_name
			end
		end
	end
	preview = parse_subnet_preview_output(exec_ctl_args(config, args))
	if not preview.ok then
		return preview
	end
	sql = [[SELECT
		COALESCE(interface_name, ''),
		COALESCE(id, 0),
		COALESCE(vlan_id, 0),
		COALESCE(cidr, ''),
		COALESCE(gateway, ''),
		COALESCE(dns1, ''),
		COALESCE(dns2, ''),
		COALESCE(range_start, ''),
		COALESCE(range_end, ''),
		COALESCE(lease_time, ''),
		COALESCE(enabled, 0),
		COALESCE(display_name, ''),
		COALESCE(comment, '')
	FROM subnets;]]
	for _, row in ipairs(query_rows(config, sql,
		{"interface_name", "id", "vlan_id", "cidr", "gateway", "dns1", "dns2", "range_start", "range_end", "lease_time", "enabled", "display_name", "comment"},
		{id = true, vlan_id = true, enabled = true})) do
		existing[row.interface_name] = row
	end
	preview.summary = { added = 0, updated = 0, unchanged = 0 }
	for _, row in ipairs(preview.rows) do
		local current = existing[row.interface_name]
		local changed_fields = {}
		if not current then
			row.change_type = "added"
			preview.summary.added = preview.summary.added + 1
		else
			row.existing_id = current.id
			if current.vlan_id ~= row.vlan_id then changed_fields[#changed_fields + 1] = "vlan_id" end
			if current.cidr ~= row.cidr then changed_fields[#changed_fields + 1] = "cidr" end
			if current.gateway ~= row.gateway then changed_fields[#changed_fields + 1] = "gateway" end
			if current.dns1 ~= row.dns1 then changed_fields[#changed_fields + 1] = "dns1" end
			if current.dns2 ~= row.dns2 then changed_fields[#changed_fields + 1] = "dns2" end
			if current.range_start ~= row.range_start then changed_fields[#changed_fields + 1] = "range_start" end
			if current.range_end ~= row.range_end then changed_fields[#changed_fields + 1] = "range_end" end
			if current.lease_time ~= row.lease_time then changed_fields[#changed_fields + 1] = "lease_time" end
			if current.enabled ~= row.enabled then changed_fields[#changed_fields + 1] = "enabled" end
			if #changed_fields > 0 then
				row.change_type = "updated"
				row.changed_fields = changed_fields
				preview.summary.updated = preview.summary.updated + 1
			else
				row.change_type = "unchanged"
				preview.summary.unchanged = preview.summary.unchanged + 1
			end
		end
	end
	return preview
end

function M.list_leases(limit)
	local config = load_config()
	local sql = string.format([[SELECT
		lease_scope.id,
		COALESCE(%s, 0),
		COALESCE(lease_scope.mac, ''),
		COALESCE(lease_scope.ip, ''),
		COALESCE(lease_scope.hostname, ''),
		COALESCE(lease_scope.vlan_id, 0),
		COALESCE(lease_scope.lease_start, ''),
		COALESCE(lease_scope.lease_end, ''),
		COALESCE(lease_scope.state, ''),
		COALESCE(lease_scope.seen_at, ''),
		COALESCE(lease_scope.updated_at, ''),
		COALESCE(lease_scope.source, '')
		,COALESCE(lease_scope.lease_duration, 0), COALESCE(lease_scope.expiry_kind, 'unknown')
	FROM leases lease_scope
	WHERE %s
	ORDER BY lease_scope.updated_at DESC, lease_scope.id DESC
	LIMIT %d;]], selected_subnet_id_for_lease("lease_scope"), selected_subnet_exists_for_lease("lease_scope"), limit)

	return query_rows(config, sql,
		{"id", "subnet_id", "mac", "ip", "hostname", "vlan_id", "lease_start", "lease_end", "state", "seen_at", "updated_at", "source", "lease_duration", "expiry_kind"},
		{id = true, subnet_id = true, vlan_id = true, lease_duration = true}
	)
end

function M.refresh_leases()
	local config = load_config()
	return run_lease_refresh(config, true)
end

function M.list_leases_changed(since, limit)
	local config = load_config()
	local escaped_since = (since or ""):gsub("'", "''")
	local sql = string.format([[SELECT
		lease_scope.id,
		COALESCE(%s, 0),
		COALESCE(lease_scope.mac, ''),
		COALESCE(lease_scope.ip, ''),
		COALESCE(lease_scope.hostname, ''),
		COALESCE(lease_scope.vlan_id, 0),
		COALESCE(lease_scope.lease_start, ''),
		COALESCE(lease_scope.lease_end, ''),
		COALESCE(lease_scope.state, ''),
		COALESCE(lease_scope.seen_at, ''),
		COALESCE(lease_scope.updated_at, ''),
		COALESCE(lease_scope.source, '')
		,COALESCE(lease_scope.lease_duration, 0), COALESCE(lease_scope.expiry_kind, 'unknown')
	FROM leases lease_scope
	WHERE lease_scope.updated_at > '%s'
	  AND %s
	ORDER BY lease_scope.updated_at ASC, lease_scope.id ASC
	LIMIT %d;]], selected_subnet_id_for_lease("lease_scope"), escaped_since, selected_subnet_exists_for_lease("lease_scope"), limit)
	return query_rows(config, sql,
		{"id", "subnet_id", "mac", "ip", "hostname", "vlan_id", "lease_start", "lease_end", "state", "seen_at", "updated_at", "source", "lease_duration", "expiry_kind"},
		{id = true, subnet_id = true, vlan_id = true, lease_duration = true}
	)
end

function M.list_events(limit)
	local config = load_config()
	local sql = string.format([[SELECT
		event_scope.id,
		COALESCE(event_scope.event_type, ''),
		COALESCE(event_scope.mac, ''),
		COALESCE(event_scope.ip, ''),
		COALESCE(event_scope.hostname, ''),
		COALESCE(event_scope.subnet_id, 0),
		COALESCE(event_scope.vlan_id, 0),
		COALESCE(REPLACE(REPLACE(event_scope.detail, char(10), ' '), char(9), ' '), ''),
		COALESCE(event_scope.created_at, '')
	FROM events event_scope
	WHERE %s
	ORDER BY event_scope.id DESC
	LIMIT %d;]], selected_subnet_exists_for_event("event_scope"), limit)

	return query_rows(config, sql,
		{"id", "event_type", "mac", "ip", "hostname", "subnet_id", "vlan_id", "detail", "created_at"},
		{id = true, subnet_id = true, vlan_id = true}
	)
end

function M.list_events_since(after_id, limit)
	local config = load_config()
	local sql = string.format([[SELECT
		event_scope.id,
		COALESCE(event_scope.event_type, ''),
		COALESCE(event_scope.mac, ''),
		COALESCE(event_scope.ip, ''),
		COALESCE(event_scope.hostname, ''),
		COALESCE(event_scope.subnet_id, 0),
		COALESCE(event_scope.vlan_id, 0),
		COALESCE(REPLACE(REPLACE(event_scope.detail, char(10), ' '), char(9), ' '), ''),
		COALESCE(event_scope.created_at, '')
	FROM events event_scope
	WHERE event_scope.id > %d
	  AND %s
	ORDER BY event_scope.id ASC
	LIMIT %d;]], after_id or 0, selected_subnet_exists_for_event("event_scope"), limit)
	return query_rows(config, sql,
		{"id", "event_type", "mac", "ip", "hostname", "subnet_id", "vlan_id", "detail", "created_at"},
		{id = true, subnet_id = true, vlan_id = true}
	)
end

function M.run_export_hosts()
	local config = load_config()
	return export_path(config, exec_ctl(config, "export-hosts"))
end

function M.run_export_scope()
	local config = load_config()
	return export_path(config, exec_ctl(config, "export-scope"))
end

function M.run_export_full()
	local config = load_config()
	return export_path(config, exec_ctl(config, "export-full"))
end

function M.run_export_dnsmasq()
	local config = load_config()
	return export_path(config, exec_ctl(config, "export-dnsmasq"))
end


function M.sync_subnets(options)
	local config = load_config()
	local args = { "subnet-sync" }
	local result
	local interfaces = options and options.interfaces or nil
	if type(interfaces) == "table" then
		for _, interface_name in ipairs(interfaces) do
			if interface_name and interface_name ~= "" then
				args[#args + 1] = "--interface"
				args[#args + 1] = interface_name
			end
		end
	end
	result = parse_key_value_output(exec_ctl_args(config, args))
	if result.ok then
		return result
	end
	return enrich_command_error(config, "subnet-sync", result.error)
end

function M.save_subnet_metadata(subnet)
	local config = load_config()
	return parse_key_value_output(exec_ctl_args(config, {
		"subnet-meta",
		"--id", tostring(subnet.id or ""),
		"--display-name", subnet.display_name or "",
		"--comment", subnet.comment or ""
	}))
end

function M.save_host(host)
	local config = load_config()
	local args = { "host-upsert" }
	if host.id and host.id ~= "" then
		args[#args + 1] = "--id"
		args[#args + 1] = tostring(host.id)
	end
	args[#args + 1] = "--hostname"
	args[#args + 1] = host.hostname or ""
	args[#args + 1] = "--mac"
	args[#args + 1] = host.mac or ""
	args[#args + 1] = "--ip"
	args[#args + 1] = host.ip or ""
	args[#args + 1] = "--subnet-id"
	args[#args + 1] = host.subnet_id or ""
	args[#args + 1] = "--type"
	args[#args + 1] = host.type or ""
	args[#args + 1] = "--owner"
	args[#args + 1] = host.owner or ""
	args[#args + 1] = "--comment"
	args[#args + 1] = host.comment or ""
	args[#args + 1] = "--reserved"
	args[#args + 1] = host.reserved or "1"
	args[#args + 1] = "--enabled"
	args[#args + 1] = host.enabled or "1"
	return parse_key_value_output(exec_ctl_args(config, args))
end

function M.delete_host(host_id)
	local config = load_config()
	return parse_key_value_output(exec_ctl_args(config, { "host-delete", tostring(host_id) }))
end

return M