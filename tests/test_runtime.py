#!/usr/bin/env python3
import concurrent.futures
import json
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import time
import unittest


PACKAGE = Path(__file__).resolve().parents[1]


class RuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="lite-ipam-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = self.root / "data"
        for directory in ("db", "dnsmasq/pending", "dnsmasq/active", "tmp/status", "logs", "backup", "export"):
            (self.data / directory).mkdir(parents=True, exist_ok=True)
        self.db_path = self.data / "db/ipam.db"
        self.db = sqlite3.connect(self.db_path)
        self.addCleanup(self.db.close)
        self.db.executescript((PACKAGE / "files/schema-v1.sql").read_text())
        self.db.executescript("""
            PRAGMA user_version=2;
            INSERT INTO subnets(id,vlan_id,name,cidr,interface_name,created_at,updated_at)
            VALUES(1,100,'test','192.168.100.1/24','vlan100','2026-01-01','2026-01-01'),
                  (2,110,'other','192.168.110.1/24','vlan110','2026-01-01','2026-01-01');
        """)
        (self.data / "dnsmasq/active/hosts.conf").write_text("")
        self.leasefile = self.root / "dhcp.leases"
        self.leasefile.write_text("")
        source = (PACKAGE / "files/lite-ipam.sh").read_text()
        source = source.replace(". /lib/functions.sh", "")
        source = source.split('if should_auto_repair_dnsmasq_hook "$1"; then')[0]
        self.harness = self.root / "runtime.sh"
        self.harness.write_text(source + r'''
load_core_config() {
    lite_ipam_enabled="${TEST_ENABLED:-1}"
    lite_ipam_data_root="$TEST_DATA"
    lite_ipam_apply_mode=immediate
    lite_ipam_backup_mail_enabled=0
    lite_ipam_backup_retention_days=30
}
runtime_log_path() { printf '%s/logs/runtime.log' "$TEST_DATA"; }
uci_typed_get() {
    case "$1.$2" in
        sync.subnet_interfaces) printf '%s' "$TEST_INTERFACES" ;;
        *) printf '%s' "$3" ;;
    esac
}
uci() {
    case "$*" in
        "-q get dhcp.main.leasefile") printf '%s' "$TEST_LEASEFILE" ;;
        "-q get dhcp.second.leasefile") printf '%s' "$TEST_SECOND_LEASEFILE" ;;
        *) return 1 ;;
    esac
}
list_target_dnsmasq_sections() { printf '%s' "${TEST_SECTIONS:-main}"; }
dnsmasq() {
    if [ "$1" = --version ]; then
        printf 'Compile time options: IPv6 %s DHCP \n' "${TEST_RTC:-no-RTC}"
    else
        "$DNSMASQ_BIN" "$@"
    fi
}
logger() { printf '%s\n' "$*" >> "$TEST_DATA/tmp/journal"; }
logread() { cat "$TEST_DATA/tmp/journal"; }
reload_dnsmasq() {
    printf 'reload\n' >> "$TEST_DATA/tmp/reloads"
    [ "$TEST_RELOAD_FAIL" != 1 ] || return 1
    [ "$TEST_LOAD_FAIL" = 1 ] || printf 'dnsmasq-dhcp: read %s\n' "$LITE_IPAM_HOSTS_CONF_PATH" >> "$TEST_DATA/tmp/journal"
}
ensure_dnsmasq_integration() { return 0; }
ensure_dnsmasq_lease_hook() { return 0; }
dnsmasq_option_matches_target_sections() { return 0; }
init_data_root() { load_core_config; derive_paths; }
load_core_config
derive_paths
SCHEMA_PATH="$TEST_SCHEMA"
''')
        self.env = dict(os.environ, TEST_DATA=str(self.data),
                        TEST_LEASEFILE=str(self.leasefile), TEST_INTERFACES="vlan100",
                        TEST_SCHEMA=str(PACKAGE / "files/schema-v1.sql"),
                        DNSMASQ_BIN=os.environ.get("DNSMASQ_BIN", shutil.which("dnsmasq") or ""))

    def run_shell(self, command, check=True, **environment):
        result = subprocess.run(
            ["busybox", "ash", "-c", f". {shlex.quote(str(self.harness))}; {command}"],
            env=dict(self.env, **environment), capture_output=True, text=True, timeout=40)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def event(self, mac="02:00:00:00:00:01", ip="192.168.100.20",
              action="add", hostname="test-host", **env):
        args = ["--action", action, "--mac", mac, "--ip", ip, "--hostname", hostname]
        return self.run_shell("run_lease_event " + shlex.join(args), **env)

    def scalar(self, sql):
        return self.db.execute(sql).fetchone()[0]

    def status(self, name):
        return json.loads((self.data / f"tmp/status/{name}.json").read_text())

    def test_status_failure_and_recovery_history(self):
        self.run_shell("""write_status_json publication false 'load failed' '"detail": "test failure"'""")
        failure = self.status("publication.last-failure")
        self.assertFalse(failure["ok"])
        self.assertEqual(failure["detail"], "test failure")
        self.run_shell("write_status_json publication true 'load verified'")
        recovery = self.status("publication.recovery")
        self.assertTrue(recovery["ok"])
        self.run_shell("write_status_json publication true 'load verified again'")
        self.assertEqual(self.status("publication.recovery"), recovery)
        self.assertEqual(self.status("publication.last-failure"), failure)
        self.run_shell("write_status_json publication false 'new failure'")
        self.assertFalse((self.data / "tmp/status/publication.recovery.json").exists())
        self.assertEqual(self.status("publication.last-failure")["message"], "new failure")

    def test_health_classification(self):
        lua = os.environ.get("LUA_BIN") or shutil.which("lua") or str(
            PACKAGE.parents[3] / "staging_dir/hostpkg/bin/lua")
        result = subprocess.run(
            [lua, str(PACKAGE / "tests/test_health.lua"),
             str(PACKAGE / "files/luci/model/lite_ipam.lua")],
            capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_overview_health_rendering(self):
        result = subprocess.run(
            ["node", str(PACKAGE / "tests/test_overview.js")],
            capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_hosts_file_format_and_unchanged_publication(self):
        self.event()
        self.run_shell("with_runtime_lock publication publish_hosts_locked")
        hosts = (self.data / "dnsmasq/active/hosts.conf").read_text()
        self.assertIn("02:00:00:00:00:01,192.168.100.20,test-host", hosts)
        self.assertNotIn("dhcp-host=", hosts)
        self.assertTrue(self.status("publication")["load_verified"])
        self.assertFalse((self.data / "tmp/hosts.dirty").exists())
        self.run_shell("reload_dnsmasq_deferred; with_runtime_lock publication publish_hosts_locked")
        self.assertEqual((self.data / "tmp/reloads").read_text().count("reload"), 1)

    def test_invalid_reservation_preserves_previous_file(self):
        self.event()
        self.run_shell("generate_hosts_conf")
        old = (self.data / "dnsmasq/active/hosts.conf").read_bytes()
        self.db.execute("UPDATE hosts SET hostname='bad,hostname'")
        self.db.commit()
        self.assertNotEqual(self.run_shell("generate_hosts_conf", check=False).returncode, 0)
        self.assertEqual((self.data / "dnsmasq/active/hosts.conf").read_bytes(), old)
        self.assertFalse(self.status("generation")["ok"])

    def test_no_rtc_snapshot_does_not_invent_expiry(self):
        self.leasefile.write_text("43200 02:00:00:00:00:01 192.168.100.20 host *\n")
        self.run_shell("run_lease_sync")
        self.run_shell("run_lease_sync")
        self.assertEqual(self.scalar("SELECT count(*) FROM leases WHERE state='active'"), 1)
        self.assertIsNone(self.scalar("SELECT lease_end FROM leases"))
        self.assertEqual(self.scalar("SELECT lease_duration FROM leases"), 43200)
        self.assertEqual(self.scalar("SELECT expiry_kind FROM leases"), "duration_only")

    def test_hook_remaining_is_preserved_by_snapshot(self):
        self.event(DNSMASQ_TIME_REMAINING="300", DNSMASQ_LEASE_LENGTH="43200")
        expiry = self.scalar("SELECT lease_end FROM leases")
        self.assertTrue(expiry)
        self.leasefile.write_text("43200 02:00:00:00:00:01 192.168.100.20 host *\n")
        self.run_shell("run_lease_sync")
        self.assertEqual(self.scalar("SELECT lease_end FROM leases"), expiry)
        self.assertEqual(self.scalar("SELECT expiry_kind FROM leases"), "hook_remaining")

    def test_absolute_and_infinite_leases(self):
        future = int(time.time()) + 3600
        self.leasefile.write_text(
            f"{future} 02:00:00:00:00:01 192.168.100.20 host *\n"
            "0 02:00:00:00:00:02 192.168.100.21 infinite *\n")
        self.run_shell("run_lease_sync", TEST_RTC="RTC")
        self.assertEqual(self.scalar("SELECT count(*) FROM leases WHERE state='active'"), 2)
        self.assertEqual(self.scalar("SELECT expiry_kind FROM leases WHERE ip LIKE '%.20'"), "absolute")
        self.assertIsNone(self.scalar("SELECT lease_end FROM leases WHERE ip LIKE '%.21'"))

    def test_reconciliation_expires_missing_and_preserves_out_of_scope(self):
        self.event()
        self.event(mac="02:00:00:00:00:02", ip="192.168.110.20",
                   TEST_INTERFACES="vlan100 vlan110")
        self.run_shell("run_lease_sync")
        self.assertEqual(self.scalar("SELECT state FROM leases WHERE subnet_id=1"), "expired")
        self.assertEqual(self.scalar("SELECT state FROM leases WHERE subnet_id=2"), "active")

    def test_released_history_does_not_block_reacquisition(self):
        self.event()
        self.event(action="del")
        self.event()
        self.event(action="del")
        self.assertEqual(self.scalar("SELECT count(*) FROM leases WHERE state='released'"), 2)
        self.assertEqual(self.scalar("SELECT count(*) FROM leases WHERE state='active'"), 0)

    def test_conflicts_do_not_overwrite_fixed_hosts(self):
        self.event()
        self.event(mac="02:00:00:00:00:02")
        self.event(mac="02:00:00:00:00:02")
        self.assertEqual(self.scalar("SELECT count(*) FROM hosts"), 1)
        self.assertEqual(self.scalar("SELECT mac FROM hosts"), "02:00:00:00:00:01")
        self.assertEqual(self.scalar("SELECT count(*) FROM events WHERE event_type='lease_ip_conflict'"), 1)
        self.assertEqual(self.scalar("SELECT count(*) FROM leases WHERE state='active'"), 1)
        self.assertEqual(self.scalar("SELECT state FROM leases WHERE mac='02:00:00:00:00:01'"), "superseded")

    def test_missing_and_malformed_snapshot_do_not_expire_leases(self):
        self.event()
        self.leasefile.unlink()
        self.assertNotEqual(self.run_shell("run_lease_sync", check=False).returncode, 0)
        self.leasefile.write_text("43200 invalid 192.168.100.20 hostname *\n")
        self.assertNotEqual(self.run_shell("run_lease_sync", check=False).returncode, 0)
        self.assertEqual(self.scalar("SELECT state FROM leases"), "active")

    def test_duplicate_snapshot_rolls_back_whole_transaction(self):
        self.event()
        self.leasefile.write_text(
            "43200 02:00:00:00:00:02 192.168.100.21 host *\n"
            "43200 02:00:00:00:00:03 192.168.100.21 host *\n")
        self.assertNotEqual(self.run_shell("run_lease_sync", check=False).returncode, 0)
        self.assertEqual(self.scalar("SELECT count(*) FROM hosts"), 1)
        self.assertEqual(self.scalar("SELECT state FROM leases"), "active")
        self.assertEqual(self.status("database")["failures"], 1)
        self.assertIn("UNIQUE", self.status("database")["detail"])

    def test_parallel_events_are_serialized(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda i: self.event(mac=f"02:00:00:00:01:{i:02x}",
                                              ip=f"192.168.100.{30+i}"), range(16)))
        self.assertEqual(self.scalar("SELECT count(*) FROM hosts"), 16)
        self.assertEqual(self.scalar("SELECT count(*) FROM leases WHERE state='active'"), 16)
        self.assertFalse((self.data / "tmp/status/database.json").exists())

    def test_short_sqlite_writer_contention_is_retried(self):
        self.db.execute("BEGIN IMMEDIATE")
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            event = pool.submit(self.event)
            time.sleep(0.3)
            self.db.commit()
            event.result()
        self.assertEqual(self.scalar("SELECT count(*) FROM hosts"), 1)
        self.assertFalse((self.data / "tmp/status/database.json").exists())

    def test_sql_failure_rolls_back_prior_writes_and_reports_cause(self):
        self.event()
        sql = ("BEGIN IMMEDIATE; UPDATE hosts SET hostname='changed'; "
               "INSERT INTO hosts(mac,ip,subnet_id,vlan_id,created_at,updated_at) "
               "VALUES('02:00:00:00:00:99','192.168.100.99',999,100,'',''); COMMIT;")
        result = self.run_shell("sqlite3 \"$LITE_IPAM_DB_PATH\" " + shlex.quote(sql),
                                check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.scalar("SELECT hostname FROM hosts"), "test-host")
        self.assertIn("FOREIGN KEY", self.status("database")["detail"])

    def test_sql_statement_boundaries_preserve_quoted_semicolons(self):
        sql = "SELECT 'a'';b'; /* ; */ SELECT 'second;value'; -- ;\nSELECT 3;"
        result = self.run_shell("sqlite3 \"$LITE_IPAM_DB_PATH\" " + shlex.quote(sql))
        self.assertEqual(result.stdout.strip().splitlines(), ["a';b", "second;value", "3"])

    def test_multiple_instance_leasefiles(self):
        second = self.root / "second.leases"
        self.leasefile.write_text("43200 02:00:00:00:00:01 192.168.100.20 one *\n")
        second.write_text("43200 02:00:00:00:00:02 192.168.110.20 two *\n")
        self.run_shell("run_lease_sync", TEST_SECTIONS="main second",
                       TEST_SECOND_LEASEFILE=str(second), TEST_INTERFACES="vlan100 vlan110")
        self.assertEqual(self.scalar("SELECT count(*) FROM leases WHERE state='active'"), 2)

    def test_invalid_input_and_disabled_service(self):
        result = self.run_shell("run_lease_event --action add --mac bad --ip 192.168.100.20",
                                check=False)
        self.assertNotEqual(result.returncode, 0)
        self.event(TEST_ENABLED="0")
        self.assertEqual(self.scalar("SELECT count(*) FROM leases"), 0)
        for ip in ("999.1.1.1", "192.168.01.2", "1.2.3", "1.2.3.4.5"):
            self.assertNotEqual(self.run_shell("valid_ipv4 " + shlex.quote(ip),
                                              check=False).returncode, 0)

    def test_failed_reload_retains_dirty_and_last_good_file(self):
        self.event()
        self.run_shell("with_runtime_lock publication publish_hosts_locked")
        old = (self.data / "dnsmasq/active/hosts.conf").read_bytes()
        self.event(mac="02:00:00:00:00:02", ip="192.168.100.21")
        result = self.run_shell("with_runtime_lock publication publish_hosts_locked",
                                check=False, TEST_RELOAD_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.status("publication")["ok"])
        self.assertEqual((self.data / "dnsmasq/active/hosts.conf").read_bytes(), old)
        self.assertTrue((self.data / "tmp/hosts.dirty").exists())

    def test_successful_reload_without_load_evidence_is_not_success(self):
        self.event()
        result = self.run_shell("with_runtime_lock publication publish_hosts_locked",
                                check=False, TEST_LOAD_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.status("publication")["load_verified"])
        self.assertTrue((self.data / "tmp/hosts.dirty").exists())

    def test_atomic_publication_keeps_mounted_directory_and_no_extra_hostfiles(self):
        active = self.data / "dnsmasq/active"
        inode = active.stat().st_ino
        self.event()
        self.run_shell("with_runtime_lock publication publish_hosts_locked")
        self.event(mac="02:00:00:00:00:02", ip="192.168.100.21")
        self.run_shell("with_runtime_lock publication publish_hosts_locked")
        self.assertEqual(active.stat().st_ino, inode)
        self.assertEqual([path.name for path in active.iterdir()], ["hosts.conf"])
        self.assertTrue((self.data / "dnsmasq/hosts.last-good").exists())
        self.assertEqual((self.data / "tmp/reloads").read_text().count("reload"), 2)

    def test_worker_stops_with_its_tracked_process_and_can_restart(self):
        def start():
            return subprocess.Popen(
                ["busybox", "ash", "-c",
                 f". {shlex.quote(str(self.harness))}; run_worker"],
                env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        for _ in range(2):
            process = start()
            try:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    path = self.data / "tmp/status/worker.json"
                    if path.exists() and self.status("worker")["pid"] == process.pid:
                        break
                    time.sleep(0.1)
                self.assertEqual(self.status("worker")["pid"], process.pid)
                self.assertIsNone(process.poll())
            finally:
                process.terminate()
                process.wait(timeout=10)

    def test_invalid_manual_host_and_missing_edit_are_rejected(self):
        args = ("run_host_upsert --mac 02:00:00:00:00:01 "
                "--hostname valid --subnet-id 1 ")
        self.assertNotEqual(self.run_shell(args + "--ip 192.168.110.20",
                                          check=False).returncode, 0)
        self.assertNotEqual(self.run_shell(args + "--id 999 --ip 192.168.100.20",
                                          check=False).returncode, 0)
        self.assertEqual(self.scalar("SELECT count(*) FROM hosts"), 0)

    def test_json_status_escapes_control_characters(self):
        self.run_shell("write_status_json test false \"$(printf 'line\\tone\\nline two\\r')\"")
        self.assertEqual(self.status("test")["message"], "line\tone\nline two\r")

    def test_backup_contains_consistent_database_at_original_path(self):
        self.event()
        self.run_shell("run_backup_now")
        archive = next((self.data / "backup").glob("*.tar.gz"))
        with tarfile.open(archive) as tar:
            member = tar.extractfile("data/db/ipam.db")
            restored = self.root / "restored.db"
            restored.write_bytes(member.read())
        with sqlite3.connect(restored) as db:
            self.assertEqual(db.execute("PRAGMA quick_check").fetchone()[0], "ok")
            self.assertEqual(db.execute("SELECT count(*) FROM hosts").fetchone()[0], 1)

    def test_schema_migration_retains_history_and_enforces_current_uniqueness(self):
        self.event()
        self.db.execute("INSERT INTO leases(mac,ip,subnet_id,vlan_id,state,seen_at,updated_at) "
                        "VALUES('02:00:00:00:00:02','192.168.100.20',1,100,'active','','')")
        self.db.commit()
        self.run_shell("ensure_sqlite_migrations")
        self.assertEqual(self.scalar("SELECT count(*) FROM leases"), 2)
        self.assertEqual(self.scalar("SELECT count(*) FROM leases WHERE state='active'"), 1)
        self.assertEqual(self.scalar("PRAGMA user_version"), 2)
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO leases(mac,ip,subnet_id,vlan_id,state,seen_at,updated_at) "
                            "VALUES('02:00:00:00:00:03','192.168.100.20',1,100,'active','','')")

    def test_existing_schema_gets_new_lease_columns(self):
        legacy = (PACKAGE / "files/schema-v1.sql").read_text()
        legacy = legacy.replace("    lease_duration INTEGER,\n", "")
        legacy = legacy.replace("    expiry_kind TEXT NOT NULL DEFAULT 'unknown',\n", "")
        self.db.executescript("DROP TABLE leases;" + legacy + "PRAGMA user_version=1;")
        self.run_shell("ensure_sqlite_schema")
        columns = {row[1] for row in self.db.execute("PRAGMA table_info(leases)")}
        self.assertTrue({"lease_duration", "expiry_kind"} <= columns)
        self.assertEqual(self.scalar("PRAGMA user_version"), 2)


if __name__ == "__main__":
    unittest.main()
