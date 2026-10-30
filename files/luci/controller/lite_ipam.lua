module("luci.controller.lite_ipam", package.seeall)

local function current_api_enabled()
	local uci = require "luci.model.uci".cursor()
	local enabled = uci:get_first("lite-ipam", "api", "enabled") or "0"
	return enabled == "1" or enabled == "true"
end

local function current_read_token()
	local uci = require "luci.model.uci".cursor()
	return uci:get_first("lite-ipam", "api", "read_token") or ""
end

local function current_write_token()
	local uci = require "luci.model.uci".cursor()
	return uci:get_first("lite-ipam", "api", "write_token") or ""
end

local function configured_page_size(option_name, fallback, hard_max)
	local uci = require "luci.model.uci".cursor()
	local value = tonumber(uci:get_first("lite-ipam", "api", option_name)) or fallback

	if value < 1 then
		value = fallback
	end

	if hard_max and value > hard_max then
		value = hard_max
	end

	return value
end

local function request_path_info()
	local http = require "luci.http"
	return http.getenv("PATH_INFO") or ""
end

local function is_public_api_request()
	local path_info = request_path_info()
	return path_info:match("^/lite%-ipam/api/v1/") ~= nil
		or path_info:match("^/cgi%-bin/luci/lite%-ipam/api/v1/") ~= nil
end

local function enforce_public_api_enabled()
	local http = require "luci.http"
	if not is_public_api_request() then
		return true
	end
	if current_api_enabled() then
		return true
	end
	http.status(503, "Service Unavailable")
	http.prepare_content("application/json")
	http.write_json({ ok = false, error = "public api is disabled" })
	return false
end

local function request_token()
	local http = require "luci.http"
	local auth = http.getenv("HTTP_AUTHORIZATION") or ""
	local bearer = auth:match("^[Bb]earer%s+(.+)$")
	return http.formvalue("token", true)
		or http.getenv("HTTP_X_LITE_IPAM_TOKEN")
		or bearer
		or ""
end

local function request_write_token()
	local http = require "luci.http"
	local auth = http.getenv("HTTP_AUTHORIZATION") or ""
	local bearer = auth:match("^[Bb]earer%s+(.+)$")
	return http.formvalue("write_token")
		or http.formvalue("token")
		or http.getenv("HTTP_X_LITE_IPAM_WRITE_TOKEN")
		or http.getenv("HTTP_X_LITE_IPAM_TOKEN")
		or bearer
		or ""
end

local function set_read_refresh_mode(public_request)
	local api = require "luci.model.lite_ipam"
	api.set_auto_refresh(not public_request)
end

local function has_admin_write_marker()
	local http = require "luci.http"
	local marker = http.getenv("HTTP_X_REQUESTED_WITH") or ""
	local form_marker = http.formvalue("_lite_ipam_request") or ""
	return marker == "XMLHttpRequest" or marker == "lite-ipam" or form_marker == "1"
end

local function enforce_read_auth()
	local http = require "luci.http"
	local configured_token = current_read_token()
	local public_request = is_public_api_request()
	if not enforce_public_api_enabled() then
		return false
	end
	if public_request then
		if configured_token ~= "" and request_token() == configured_token then
			set_read_refresh_mode(true)
			return true
		end
		http.status(403, "Forbidden")
		http.prepare_content("application/json")
		http.write_json({ ok = false, error = configured_token == "" and "read token is not configured" or "invalid token" })
		return false
	end
	set_read_refresh_mode(false)
	return true
end

local function enforce_write_auth()
	local http = require "luci.http"
	local configured_token = current_write_token()
	local public_request = is_public_api_request()
	if public_request then
		if configured_token ~= "" and request_write_token() == configured_token then
			return true
		end
		http.status(403, "Forbidden")
		http.prepare_content("application/json")
		http.write_json({ ok = false, error = configured_token == "" and "write token is not configured" or "invalid write token" })
		return false
	end
	if has_admin_write_marker() then
		return true
	end
	http.status(403, "Forbidden")
	http.prepare_content("application/json")
	http.write_json({ ok = false, error = "missing request marker" })
	return false
end

local function respond_bad_request(message)
	local http = require "luci.http"
	http.status(400, "Bad Request")
	http.prepare_content("application/json")
	http.write_json({ ok = false, error = message or "bad request" })
	return false
end

local function respond_method_not_allowed(method)
	local http = require "luci.http"
	http.status(405, "Method Not Allowed")
	http.prepare_content("application/json")
	http.write_json({ ok = false, error = "expected " .. (method or "POST") })
	return false
end

local function log_controller_error(action_name, err)
	local sys = require "luci.sys"
	sys.call(string.format("logger -t %s %s >/dev/null 2>&1", "lite-ipam", string.format("%q", "[LuciError] " .. tostring(action_name or "unknown") .. ": " .. tostring(err or "unknown error"))))
end

local function safe_json(action_name, callback)
	local http = require "luci.http"
	local ok, result = xpcall(callback, debug.traceback)
	if ok then
		return result
	end
	log_controller_error(action_name, result)
	http.status(500, "Internal Server Error")
	http.prepare_content("application/json")
	http.write_json({ ok = false, error = "internal server error", action = action_name, detail = tostring(result or "unknown error") })
	return nil
end

local function request_host_id()
	local http = require "luci.http"
	local path_info = http.getenv("PATH_INFO") or ""
	local host_id = tonumber(http.formvalue("id", true))
	if host_id then
		return host_id
	end
	host_id = tonumber(path_info:match("/api/v1/host/([0-9]+)$"))
	if host_id then
		return host_id
	end
	return nil
end

function index()
	local root
	local api
	local public_api

	root = entry({"admin", "services", "lite-ipam"}, alias("admin", "services", "lite-ipam", "overview"), _("Lite IPAM"), 90)
	root.dependent = false

	api = entry({"admin", "services", "lite-ipam", "api", "v1"}, firstchild(), nil)
	api.dependent = false

	public_api = entry({"lite-ipam", "api", "v1"}, firstchild(), nil)
	public_api.dependent = false
	public_api.sysauth = false

	entry({"admin", "services", "lite-ipam", "api", "v1", "status"}, call("action_status")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "overview", "summary"}, call("action_overview_summary")).leaf = true
		entry({"admin", "services", "lite-ipam", "api", "v1", "overview", "recent-hosts"}, call("action_overview_recent_hosts")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "sync", "batch"}, call("action_sync_batch")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "sync", "cursor"}, call("action_sync_cursor")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "settings"}, call("action_settings")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "settings", "save"}, call("action_settings_save")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "hosts"}, call("action_hosts")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "hosts", "changed"}, call("action_hosts_changed")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "hosts", "detail"}, call("action_host_detail")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "hosts", "save"}, call("action_host_save")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "hosts", "delete"}, call("action_host_delete")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "host"}, call("action_host_detail_path")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "subnets"}, call("action_subnets")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "subnets", "candidates"}, call("action_subnet_candidates")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "subnets", "selection"}, call("action_subnet_selection")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "subnets", "selection", "save"}, call("action_subnet_selection_save")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "subnets", "preview"}, call("action_subnet_preview")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "subnets", "changed"}, call("action_subnets_changed")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "subnets", "sync"}, call("action_subnets_sync")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "subnets", "meta-save"}, call("action_subnet_meta_save")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "leases"}, call("action_leases")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "leases", "changed"}, call("action_leases_changed")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "leases", "refresh"}, call("action_leases_refresh")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "events"}, call("action_events")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "events", "since"}, call("action_events_since")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "backup", "status"}, call("action_backup_status")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "cleanup", "status"}, call("action_cleanup_status")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "export", "hosts"}, call("action_export_hosts")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "export", "scope"}, call("action_export_scope")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "export", "full"}, call("action_export_full")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "export", "dnsmasq"}, call("action_export_dnsmasq")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "storage", "status"}, call("action_storage_status")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "health"}, call("action_health")).leaf = true
	entry({"admin", "services", "lite-ipam", "api", "v1", "logs", "recent"}, call("action_logs_recent")).leaf = true

	entry({"lite-ipam", "api", "v1", "status"}, call("action_status")).leaf = true
	entry({"lite-ipam", "api", "v1", "sync", "batch"}, call("action_sync_batch")).leaf = true
	entry({"lite-ipam", "api", "v1", "sync", "cursor"}, call("action_sync_cursor")).leaf = true
	entry({"lite-ipam", "api", "v1", "hosts"}, call("action_hosts")).leaf = true
	entry({"lite-ipam", "api", "v1", "hosts", "changed"}, call("action_hosts_changed")).leaf = true
	entry({"lite-ipam", "api", "v1", "hosts", "detail"}, call("action_host_detail")).leaf = true
	entry({"lite-ipam", "api", "v1", "host"}, call("action_host_detail_path")).leaf = true
	entry({"lite-ipam", "api", "v1", "subnets"}, call("action_subnets")).leaf = true
	entry({"lite-ipam", "api", "v1", "subnets", "changed"}, call("action_subnets_changed")).leaf = true
	entry({"lite-ipam", "api", "v1", "leases"}, call("action_leases")).leaf = true
	entry({"lite-ipam", "api", "v1", "leases", "changed"}, call("action_leases_changed")).leaf = true
	entry({"lite-ipam", "api", "v1", "events"}, call("action_events")).leaf = true
	entry({"lite-ipam", "api", "v1", "events", "since"}, call("action_events_since")).leaf = true

	entry({"admin", "services", "lite-ipam", "overview"}, template("lite_ipam/overview"), _("Overview"), 10).leaf = true
	entry({"admin", "services", "lite-ipam", "settings"}, template("lite_ipam/settings"), _("Settings"), 12).leaf = true
	entry({"admin", "services", "lite-ipam", "subnets"}, template("lite_ipam/subnets"), _("Subnets"), 15).leaf = true
	entry({"admin", "services", "lite-ipam", "logs"}, template("lite_ipam/logs"), _("Logs"), 18).leaf = true
	entry({"admin", "services", "lite-ipam", "manage"}, template("lite_ipam/manage"), _("Manage Hosts"), 20).leaf = true
end

local function render_json(payload)
	local http = require "luci.http"
	http.prepare_content("application/json")
	http.write_json(payload)
end

local function query_limit(default_value, max_value)
	local http = require "luci.http"
	local effective_max = configured_page_size("max_page_size", max_value, max_value)
	local effective_default = configured_page_size("default_page_size", default_value, effective_max)
	local value = tonumber(http.formvalue("limit", true)) or effective_default

	if value < 1 then
		value = effective_default
	end

	if value > effective_max then
		value = effective_max
	end

	return value
end

local function render_file(file_path, mime)
	local fs = require "nixio.fs"
	local http = require "luci.http"
	if not file_path or file_path == "" then
		http.status(500, "Export Failed")
		return
	end
	local content = fs.readfile(file_path)

	if not content then
		http.status(404, "Not Found")
		return
	end

	http.prepare_content(mime)
	http.write(content)
end

function action_status()
	safe_json("status", function()
		local api = require "luci.model.lite_ipam"
		local status
		if not enforce_read_auth() then return end
		status = api.get_status()
		if is_public_api_request() then
			status.data_root = nil
			status.db_path = nil
			status.hosts_conf_path = nil
			status.backup = nil
			status.cleanup = nil
		end
		render_json(status)
	end)
end

function action_overview_summary()
	safe_json("overview_summary", function()
		local http = require "luci.http"
		local api = require "luci.model.lite_ipam"
		local summary
		if not enforce_read_auth() then return end
		if http.formvalue("force", true) == "1" then
			summary = api.get_overview_summary_uncached()
		else
			summary = api.get_overview_summary()
		end
		render_json(summary)
	end)
end

function action_overview_recent_hosts()
	safe_json("overview_recent_hosts", function()
		local api = require "luci.model.lite_ipam"
		if not enforce_read_auth() then return end
		render_json(api.list_recent_hosts(query_limit(10, 50)))
	end)
end

function action_sync_batch()
	local api = require "luci.model.lite_ipam"
	local http = require "luci.http"
	if not enforce_read_auth() then return end
	render_json(api.get_sync_batch({
		hosts_since = http.formvalue("hosts_since", true) or http.formvalue("since_hosts", true) or "",
		subnets_since = http.formvalue("subnets_since", true) or http.formvalue("since_subnets", true) or "",
		leases_since = http.formvalue("leases_since", true) or http.formvalue("since_leases", true) or "",
		events_after_id = http.formvalue("events_after_id", true) or http.formvalue("after_event_id", true) or "0",
		limit = http.formvalue("limit", true) or "100"
	}))
end

function action_sync_cursor()
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	render_json(api.get_sync_cursor())
end

function action_settings()
	safe_json("settings", function()
		local api = require "luci.model.lite_ipam"
		if not enforce_read_auth() then return end
		render_json(api.get_settings())
	end)
end

function action_settings_save()
	safe_json("settings_save", function()
		local http = require "luci.http"
		local api = require "luci.model.lite_ipam"
		local result
		if http.getenv("REQUEST_METHOD") ~= "POST" then return respond_method_not_allowed("POST") end
		if not enforce_write_auth() then return end
		result = api.save_settings({
			core_enabled = http.formvalue("core_enabled"),
			core_node_name = http.formvalue("core_node_name"),
			core_data_root = http.formvalue("core_data_root"),
			core_auto_init = http.formvalue("core_auto_init"),
			core_auto_create_subdirs = http.formvalue("core_auto_create_subdirs"),
			core_backup_retention_days = http.formvalue("core_backup_retention_days"),
			core_apply_mode = http.formvalue("core_apply_mode"),
			api_enabled = http.formvalue("api_enabled"),
			api_read_token = http.formvalue("api_read_token"),
			api_write_token = http.formvalue("api_write_token"),
			api_max_page_size = http.formvalue("api_max_page_size"),
			api_default_page_size = http.formvalue("api_default_page_size"),
			backup_enabled = http.formvalue("backup_enabled"),
			backup_cron_enabled = http.formvalue("backup_cron_enabled"),
			backup_cron_schedule = http.formvalue("backup_cron_schedule"),
			backup_mail_enabled = http.formvalue("backup_mail_enabled"),
			backup_mail_from = http.formvalue("backup_mail_from"),
			backup_mail_to = http.formvalue("backup_mail_to"),
			backup_smtp_host = http.formvalue("backup_smtp_host"),
			backup_smtp_port = http.formvalue("backup_smtp_port"),
			backup_smtp_user = http.formvalue("backup_smtp_user"),
			backup_smtp_password = http.formvalue("backup_smtp_password"),
			backup_smtp_tls = http.formvalue("backup_smtp_tls"),
			maintenance_enabled = http.formvalue("maintenance_enabled"),
			maintenance_lease_retention_days = http.formvalue("maintenance_lease_retention_days"),
			maintenance_event_retention_days = http.formvalue("maintenance_event_retention_days"),
			maintenance_vacuum_after_cleanup = http.formvalue("maintenance_vacuum_after_cleanup")
		})
		if not result.ok then
			http.status(500, "Save Failed")
		end
		render_json(result)
	end)
end

function action_hosts()
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	render_json(api.list_hosts(query_limit(100, 500)))
end

function action_hosts_changed()
	local api = require "luci.model.lite_ipam"
	local http = require "luci.http"
	if not enforce_read_auth() then return end
	render_json(api.list_hosts_changed(http.formvalue("since", true) or "", query_limit(100, 500)))
end

function action_host_detail()
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	local host_id = request_host_id()
	if not host_id then return respond_bad_request("host id is required") end
	render_json(api.get_host(host_id))
end

function action_host_detail_path(host_id)
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	host_id = tonumber(host_id) or request_host_id()
	if not host_id then return respond_bad_request("host id is required") end
	render_json(api.get_host(host_id))
end

function action_host_save()
	local http = require "luci.http"
	local api = require "luci.model.lite_ipam"
	local result
	if http.getenv("REQUEST_METHOD") ~= "POST" then return respond_method_not_allowed("POST") end
	if not enforce_write_auth() then return end
	result = api.save_host({
		id = http.formvalue("id", true),
		hostname = http.formvalue("hostname", true),
		mac = http.formvalue("mac", true),
		ip = http.formvalue("ip", true),
		subnet_id = http.formvalue("subnet_id", true),
		type = http.formvalue("type", true),
		owner = http.formvalue("owner", true),
		comment = http.formvalue("comment", true),
		reserved = http.formvalue("reserved", true),
		enabled = http.formvalue("enabled", true)
	})
	if not result.ok then
		http.status(500, "Save Failed")
	end
	render_json(result)
end

function action_host_delete()
	local http = require "luci.http"
	local api = require "luci.model.lite_ipam"
	local result
	if http.getenv("REQUEST_METHOD") ~= "POST" then return respond_method_not_allowed("POST") end
	if not enforce_write_auth() then return end
	local host_id = tonumber(http.formvalue("id", true))
	if not host_id then return respond_bad_request("host id is required") end
	result = api.delete_host(host_id)
	if not result.ok then
		http.status(500, "Delete Failed")
	end
	render_json(result)
end

function action_subnets()
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	render_json(api.list_subnets(query_limit(100, 500)))
end

function action_subnets_changed()
	local api = require "luci.model.lite_ipam"
	local http = require "luci.http"
	if not enforce_read_auth() then return end
	render_json(api.list_subnets_changed(http.formvalue("since", true) or "", query_limit(100, 500)))
end

function action_subnet_candidates()
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	render_json(api.list_subnet_sync_candidates())
end

function action_subnet_selection()
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	render_json(api.get_subnet_sync_selection())
end

local function requested_interfaces_from_form()
	local http = require "luci.http"
	local interfaces = {}
	local seen = {}
	local index = 0
	local function pick_form_value(key)
		local value = http.formvalue(key)
		if value == nil then
			value = http.formvalue(key, true)
		end
		return value
	end
	local function normalized_name(value)
		return tostring(value or ""):match("^%s*(.-)%s*$")
	end
	local function append_name(value)
		local interface_name = normalized_name(value)
		if interface_name ~= "" and interface_name ~= "__all__" and not seen[interface_name] then
			seen[interface_name] = true
			interfaces[#interfaces + 1] = interface_name
		end
	end

	append_name(pick_form_value("interface"))

	local interface_list = pick_form_value("interfaces") or pick_form_value("interfaces[]")
	if interface_list and interface_list ~= "" then
		for interface_name in tostring(interface_list):gmatch("[^,%s]+") do
			append_name(interface_name)
		end
	end

	while true do
		local interface_name = pick_form_value("interface_" .. index)
		if not interface_name then
			break
		end
		append_name(interface_name)
		index = index + 1
	end

	return interfaces
end

function action_subnet_selection_save()
	local http = require "luci.http"
	local api = require "luci.model.lite_ipam"
	local result
	if http.getenv("REQUEST_METHOD") ~= "POST" then return respond_method_not_allowed("POST") end
	if not enforce_write_auth() then return end
	result = api.save_subnet_sync_selection(requested_interfaces_from_form())
	if not result.ok then
		http.status(500, "Save Failed")
	end
	render_json(result)
end

function action_subnet_preview()
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	render_json(api.preview_subnets({ interfaces = requested_interfaces_from_form() }))
end

function action_subnets_sync()
	local http = require "luci.http"
	local api = require "luci.model.lite_ipam"
	local result
	if http.getenv("REQUEST_METHOD") ~= "POST" then return respond_method_not_allowed("POST") end
	if not enforce_write_auth() then return end
	result = api.sync_subnets({ interfaces = requested_interfaces_from_form() })
	if not result.ok then
		http.status(500, "Sync Failed")
	end
	render_json(result)
end

function action_subnet_meta_save()
	local http = require "luci.http"
	local api = require "luci.model.lite_ipam"
	local result
	if http.getenv("REQUEST_METHOD") ~= "POST" then return respond_method_not_allowed("POST") end
	if not enforce_write_auth() then return end
	result = api.save_subnet_metadata({
		id = http.formvalue("id", true),
		display_name = http.formvalue("display_name", true),
		comment = http.formvalue("comment", true)
	})
	if not result.ok then
		http.status(500, "Save Failed")
	end
	render_json(result)
end

function action_leases()
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	render_json(api.list_leases(query_limit(100, 500)))
end

function action_leases_changed()
	local api = require "luci.model.lite_ipam"
	local http = require "luci.http"
	if not enforce_read_auth() then return end
	render_json(api.list_leases_changed(http.formvalue("since", true) or "", query_limit(100, 500)))
end

function action_leases_refresh()
	local http = require "luci.http"
	local api = require "luci.model.lite_ipam"
	local result
	if http.getenv("REQUEST_METHOD") ~= "POST" then return respond_method_not_allowed("POST") end
	if not enforce_write_auth() then return end
	result = api.refresh_leases()
	if not result.ok then
		http.status(500, "Lease Refresh Failed")
	end
	render_json(result)
end

function action_events()
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	render_json(api.list_events(query_limit(100, 500)))
end

function action_events_since()
	local api = require "luci.model.lite_ipam"
	local http = require "luci.http"
	local after_id = tonumber(http.formvalue("id", true)) or 0
	if not enforce_read_auth() then return end
	render_json(api.list_events_since(after_id, query_limit(100, 500)))
end

function action_backup_status()
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	render_json(api.get_backup_status())
end

function action_cleanup_status()
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	render_json(api.get_cleanup_status())
end

function action_export_hosts()
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	render_file(api.run_export_hosts(), "application/json")
end

function action_export_scope()
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	render_file(api.run_export_scope(), "application/json")
end

function action_export_full()
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	render_file(api.run_export_full(), "application/json")
end

function action_export_dnsmasq()
	local api = require "luci.model.lite_ipam"
	if not enforce_read_auth() then return end
	render_file(api.run_export_dnsmasq(), "text/plain")
end

function action_storage_status()
	safe_json("storage_status", function()
		local api = require "luci.model.lite_ipam"
		if not enforce_read_auth() then return end
		render_json(api.get_storage_status())
	end)
end

function action_health()
	safe_json("health", function()
		local api = require "luci.model.lite_ipam"
		if not enforce_read_auth() then return end
		render_json(api.get_health())
	end)
end

function action_logs_recent()
	safe_json("logs_recent", function()
		local http = require "luci.http"
		local api = require "luci.model.lite_ipam"
		if not enforce_read_auth() then return end
		render_json(api.get_recent_logs(query_limit(50, 200), http.formvalue("source", true) or "system"))
	end)
end