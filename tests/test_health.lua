local files = {}
local worker_running = true
local enabled = true
local hostsfile = "/data/dnsmasq/active"
local cursor = {}
function cursor:get_first(package_name, section, option)
	if package_name == "dhcp" then return self:get(package_name, "main", option) end
	return nil
end
function cursor:get(_, _, option)
	if option == "dhcpscript" then return "/usr/libexec/lite-ipam/dnsmasq-lease-hook.sh" end
	if option == "dhcphostsfile" then return hostsfile end
end
function cursor:foreach(package_name, section, callback)
	if package_name == "dhcp" and section == "dnsmasq" then callback({ [".name"] = "main" }) end
end
package.loaded["luci.model.uci"] = { cursor = function() return cursor end }
package.loaded["luci.util"] = {}
package.loaded["luci.sys"] = { call = function(command)
	if command:find("kill -0", 1, true) and not worker_running then return 1 end
	return 0
end }
package.loaded["luci.jsonc"] = { parse = function(path) return files[path] end }
package.loaded["nixio.fs"] = {
	access = function(path)
		if path:find("/tmp/", 1, true) then return files[path] ~= nil end
		return true
	end,
	readfile = function(path) return path end
}
local model = assert(loadfile(arg[1]))()
local build
for index = 1, 20 do
	local name, value = debug.getupvalue(model.get_health, index)
	if not name then break end
	if name == "build_health_payload" then build = value; break end
end
assert(build, "health builder missing")
local config = {
	enabled = true, data_root = "/data", db_path = "/data/db/ipam.db",
	status_dir = "/data/tmp/status", hosts_dir = hostsfile
}
local function status(name, ok, message)
	return { name = name, ok = ok, message = message or (ok and "ok" or "failed"),
		updated_at = "2026-10-30T19:00:00Z" }
end
local function reset()
	files = {}
	worker_running = true
	enabled = true
	hostsfile = config.hosts_dir
	for _, name in ipairs({ "publication", "lease-sync", "worker" }) do
		files[config.status_dir .. "/" .. name .. ".json"] = status(name, true)
	end
	files[config.status_dir .. "/worker.json"].pid = 123
end
local function health(overrides)
	overrides = overrides or {}
	config.enabled = enabled
	return build(config, {ok = true}, overrides.generation or status("generation", true),
		overrides.hook or status("hook", true), overrides.backup or status("backup", true),
		overrides.cleanup or status("cleanup", true), overrides.export or status("export", true))
end
local function find(items, code)
	for _, item in ipairs(items) do if item.code == code then return item end end
end
reset()
assert(health().level == "ok")
files[config.status_dir .. "/database.json"] = {
	ok = false, failures = 7, updated_at = "old", detail = "old SQL error"
}
local h = health()
assert(h.ok and h.level == "ok" and #h.issues == 0)
assert(find(h.history, "database").detail == "old SQL error")
reset()
h = health({cleanup = {ok = false, message = "no status recorded"}})
assert(h.level == "ok" and #h.notices == 1)
h = health({backup = status("backup", false)})
assert(h.ok and h.level == "warning")
assert(find(h.issues, "backup").target == "settings")
reset()
files[config.status_dir .. "/publication.json"] = status("publication", false, "dnsmasq reservation load not verified")
h = health()
assert(not h.ok and h.level == "error")
assert(find(h.issues, "publication").reason:find("dnsmasq", 1, true))
reset()
files["/data/tmp/hosts.dirty"] = true
assert(health().level == "pending")
reset()
files[config.status_dir .. "/publication.last-failure.json"] = status("publication", false, "old failure")
files[config.status_dir .. "/publication.recovery.json"] = status("publication", true)
h = health()
assert(h.level == "ok" and find(h.history, "publication").recovered_at ~= "")
files[config.status_dir .. "/publication.last-failure.json"] = nil
h = health()
assert(not find(h.history, "publication"), "must not invent pre-upgrade history")
reset()
worker_running = false
h = health({backup = status("backup", false)})
assert(h.level == "error" and h.issues[1].code == "worker")
reset()
hostsfile = "/wrong"
h = health()
assert(not h.ok and find(h.issues, "hostsfile"))
reset()
enabled = false
worker_running = false
h = health()
assert(h.level == "disabled" and not find(h.issues, "worker"))
reset()
files[config.status_dir .. "/lease-sync.json"] = "invalid json"
package.loaded["luci.jsonc"].parse = function(path)
	local value = files[path]
	return type(value) == "table" and value or nil
end
h = health()
assert(not h.ok and find(h.issues, "lease-sync").reason:find("解析", 1, true))
print("health classification scenarios passed")
