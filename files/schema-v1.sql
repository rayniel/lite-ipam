PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS subnets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vlan_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    cidr TEXT NOT NULL,
    interface_name TEXT,
    gateway TEXT,
    dns1 TEXT,
    dns2 TEXT,
    range_start TEXT,
    range_end TEXT,
    lease_time TEXT,
    display_name TEXT,
    comment TEXT,
    source TEXT NOT NULL DEFAULT 'system',
    sync_status TEXT NOT NULL DEFAULT 'synced',
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS hosts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    hostname TEXT,
    mac TEXT NOT NULL,
    ip TEXT NOT NULL,
    subnet_id INTEGER NOT NULL,
    vlan_id INTEGER NOT NULL,
    type TEXT,
    owner TEXT,
    comment TEXT,
    reserved INTEGER NOT NULL DEFAULT 1,
    enabled INTEGER NOT NULL DEFAULT 1,
    source TEXT NOT NULL DEFAULT 'manual',
    reservation_type TEXT NOT NULL DEFAULT 'reserved',
    sync_status TEXT NOT NULL DEFAULT 'synced',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    last_seen TEXT,
    FOREIGN KEY(subnet_id) REFERENCES subnets(id)
);

CREATE TABLE IF NOT EXISTS leases (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    mac TEXT NOT NULL,
    ip TEXT NOT NULL,
    hostname TEXT,
    subnet_id INTEGER NOT NULL,
    vlan_id INTEGER NOT NULL,
    lease_start TEXT,
    lease_end TEXT,
    lease_duration INTEGER,
    expiry_kind TEXT NOT NULL DEFAULT 'unknown',
    state TEXT NOT NULL DEFAULT 'active',
    seen_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'dnsmasq_hook',
    FOREIGN KEY(subnet_id) REFERENCES subnets(id)
);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type TEXT NOT NULL,
    mac TEXT,
    ip TEXT,
    hostname TEXT,
    subnet_id INTEGER,
    vlan_id INTEGER,
    detail TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY(subnet_id) REFERENCES subnets(id)
);

CREATE INDEX IF NOT EXISTS idx_subnets_vlan_id
    ON subnets(vlan_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_subnets_interface_name_unique
    ON subnets(interface_name);

CREATE UNIQUE INDEX IF NOT EXISTS idx_hosts_mac_unique
    ON hosts(mac);

CREATE UNIQUE INDEX IF NOT EXISTS idx_hosts_ip_unique
    ON hosts(ip);

CREATE INDEX IF NOT EXISTS idx_hosts_subnet_id
    ON hosts(subnet_id);

CREATE INDEX IF NOT EXISTS idx_hosts_vlan_id
    ON hosts(vlan_id);

CREATE INDEX IF NOT EXISTS idx_hosts_updated_at
    ON hosts(updated_at);

CREATE INDEX IF NOT EXISTS idx_leases_mac
    ON leases(mac);

CREATE INDEX IF NOT EXISTS idx_leases_ip
    ON leases(ip);

CREATE INDEX IF NOT EXISTS idx_leases_subnet_id
    ON leases(subnet_id);

CREATE INDEX IF NOT EXISTS idx_leases_updated_at
    ON leases(updated_at);

CREATE INDEX IF NOT EXISTS idx_events_created_at
    ON events(created_at);

CREATE INDEX IF NOT EXISTS idx_events_subnet_id
    ON events(subnet_id);

CREATE INDEX IF NOT EXISTS idx_leases_current
    ON leases(subnet_id, state, mac, ip);
