"""Run with python3 -I tests/storage.py; all attack targets are disposable."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("storage", REPO / "bin/storage.py")
storage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(storage)


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="omathlete-storage-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.outside = self.root / "outside"
        self.outside.mkdir(mode=0o700)
        self.sentinel = self.outside / "sentinel"
        self.sentinel.write_bytes(b"do not change")
        self.sentinel.chmod(0o640)
        self.env = {**os.environ, "XDG_STATE_HOME": str(self.root / "state"),
                    "XDG_CACHE_HOME": str(self.root / "cache"), "OMATHLETE_TESTING": "1",
                    "OMATHLETE_CURL_BIN": str(REPO / "tests/fixture-curl")}
        self.state = self.root / "state/omarchy/settings"
        self.cache = self.root / "cache/omarchy/omathlete"

    def command(self, *args, success=True):
        result = subprocess.run([str(REPO / "bin/omathlete"), *args], env=self.env,
                                capture_output=True, text=True, timeout=15)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.sentinel.read_bytes(), b"do not change")
            self.assertEqual(stat.S_IMODE(self.sentinel.stat().st_mode), 0o640)
        return result

    def fd(self, path):
        fd = storage.open_directory(str(path))
        self.addCleanup(os.close, fd)
        return fd

    def test_normal_roundtrip_private_modes_and_cleanup(self):
        self.command("state")
        self.command("toggle-spoilers")
        self.assertTrue(json.loads(self.command("state").stdout)["spoilersHidden"])
        self.assertEqual(stat.S_IMODE((self.state / "omathlete.json").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.cache.stat().st_mode), 0o700)
        self.assertFalse(list(self.cache.glob(".work-*")))

    def test_each_state_and_cache_ancestor_rejects_symlink(self):
        for base, components in (("state", ["omarchy", "settings"]),
                                 ("cache", ["omarchy", "omathlete"])):
            for depth in range(3):
                with self.subTest(base=base, depth=depth):
                    branch = self.root / f"attack-{base}-{depth}"
                    self.env["XDG_" + base.upper() + "_HOME"] = str(branch)
                    parent = branch
                    for component in components[:depth]:
                        parent.mkdir(exist_ok=True)
                        parent = parent / component
                    parent.symlink_to(self.outside, target_is_directory=True)
                    self.command("toggle-spoilers", success=False)
                    self.assertEqual(sorted(p.name for p in self.outside.iterdir()), ["sentinel"])
                    self.env["XDG_" + base.upper() + "_HOME"] = str(self.root / base)

    def test_symlinked_state_ledger_lock_and_cache_files(self):
        self.command("state")
        for directory, name in ((self.state, "omathlete.json"),
                                (self.state, "omathlete-reminders.json"),
                                (self.state, ".omathlete.lock"),
                                (self.cache, "teams.json"), (self.cache, "mlb-12.json")):
            with self.subTest(name=name):
                path = directory / name
                old = path.read_bytes() if path.exists() else None
                path.unlink(missing_ok=True)
                path.symlink_to(self.sentinel)
                self.command("toggle-spoilers", success=False)
                path.unlink()
                if old is not None:
                    path.write_bytes(old)
                self.assertFalse(list(self.cache.glob(".work-*")))

    def test_fifo_hardlink_and_writable_file_rejected(self):
        self.command("state")
        target = self.cache / "teams.json"
        os.mkfifo(target)
        self.command("state", success=False)
        target.unlink()
        os.link(self.sentinel, target)
        self.command("state", success=False)
        target.unlink()
        target.write_text("[]")
        target.chmod(0o666)
        self.command("state", success=False)

    def test_unsafe_directory_mode_and_owner_rejected(self):
        fd = self.fd(self.root / "owned")
        os.fchmod(fd, 0o777)
        with self.assertRaises(storage.UnsafeStorage):
            storage.check_directory(fd, owned=True)
        os.fchmod(fd, 0o700)
        info = list(os.fstat(fd))
        info[4] = storage.UID + 1
        with mock.patch.object(storage.os, "fstat", return_value=os.stat_result(info)):
            with self.assertRaises(storage.UnsafeStorage):
                storage.check_directory(fd, owned=True)

    def test_dangling_symlink_relative_and_parent_paths_rejected(self):
        link = self.root / "dangling"
        link.symlink_to(self.outside / "missing", target_is_directory=True)
        for path in (str(link), "relative/path", str(self.root / "../escape")):
            with self.subTest(path=path), self.assertRaises((OSError, storage.UnsafeStorage)):
                storage.open_directory(path)
        self.assertFalse((self.outside / "missing").exists())

    def test_ancestor_exchange_cannot_redirect_descriptor_io(self):
        ancestor = self.root / "original"
        fd = self.fd(ancestor / "nested")
        storage.atomic_write(fd, "data.json", b"old")
        ancestor.rename(self.root / "moved")
        ancestor.symlink_to(self.outside, target_is_directory=True)
        storage.atomic_write(fd, "data.json", b"new")
        self.assertEqual(storage.read_file(fd, "data.json", 10)[0], b"new")
        self.assertEqual((self.root / "moved/nested/data.json").read_bytes(), b"new")
        self.assertFalse((self.outside / "nested").exists())
        with storage.staging(fd) as (state, cache):
            storage.atomic_write(state, "omathlete.json", b"{}")
            storage.atomic_write(cache, "teams.json", b"[]")
        self.assertEqual(sorted(os.listdir(fd)), ["data.json"])

    def test_leaf_exchange_between_check_and_rename_never_follows_target(self):
        fd = self.fd(self.root / "publication")
        replace = storage.os.replace
        def exchange(source, target, **kwargs):
            os.symlink(str(self.sentinel), target, dir_fd=fd)
            return replace(source, target, **kwargs)
        with mock.patch.object(storage.os, "replace", side_effect=exchange):
            storage.atomic_write(fd, "data.json", b"new")
        self.assertEqual(self.sentinel.read_bytes(), b"do not change")
        self.assertEqual(storage.read_file(fd, "data.json", 10)[0], b"new")

    def test_read_rejects_symlink_and_oversized_regular_file(self):
        fd = self.fd(self.root / "reading")
        storage.atomic_write(fd, "data.json", b"12345")
        self.assertIsNone(storage.read_file(fd, "data.json", 4))
        os.symlink(str(self.sentinel), "link.json", dir_fd=fd)
        with self.assertRaises(OSError):
            storage.read_file(fd, "link.json", 100)

    def test_cache_budgets_and_unchanged_snapshot_mtime(self):
        source = self.fd(self.root / "source")
        target = self.fd(self.root / "target")
        storage.atomic_write(source, "teams.json", b"[]", 1000000000)
        before = storage.snapshot(source, target, {"teams.json": 100})
        inode = os.stat("teams.json", dir_fd=source).st_ino
        storage.publish(target, source, before, {"teams.json": 100})
        self.assertEqual(os.stat("teams.json", dir_fd=source).st_ino, inode)
        with mock.patch.object(storage, "MAX_BYTES", 1):
            with self.assertRaises(storage.UnsafeStorage):
                storage.snapshot(source, target, {"teams.json": 100})
        self.assertEqual(storage.cache_limit("../../escape.json"), 0)

    def start_delayed_worker(self):
        self.command("state")
        state = json.loads((self.state / "omathlete.json").read_text())
        state["teams"] = [{"sport": "mlb", "teamId": "16", "teamName": "Chicago Cubs", "teamAbbrev": "CHC"}]
        (self.state / "omathlete.json").write_text(json.dumps(state))
        process = subprocess.Popen([str(REPO / "bin/omathlete"), "detail-stream", "--no-cache"],
            env={**self.env, "OMATHLETE_FIXTURE_DELAY_SPORT": "all", "OMATHLETE_FIXTURE_DELAY_SECONDS": "1"},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        self.assertEqual(json.loads(process.stdout.readline())["type"], "snapshot")
        return process

    def test_running_worker_survives_cache_ancestor_exchange_without_redirection(self):
        process = self.start_delayed_worker()
        ancestor = self.root / "cache"
        ancestor.rename(self.root / "moved-cache")
        ancestor.symlink_to(self.outside, target_is_directory=True)
        output, error = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, error)
        self.assertIn('"type":"team"', output)
        self.assertEqual(sorted(p.name for p in self.outside.iterdir()), ["sentinel"])
        moved = self.root / "moved-cache/omarchy/omathlete"
        self.assertTrue((moved / "mlb-16.json").is_file())
        self.assertFalse(list(moved.glob(".work-*")))

    def test_termination_cleans_private_staging(self):
        process = self.start_delayed_worker()
        process.terminate()
        process.communicate(timeout=10)
        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(list(self.cache.glob(".work-*")))


if __name__ == "__main__":
    unittest.main()
