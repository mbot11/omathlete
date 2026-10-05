"""Descriptor-rooted persistence boundary for the Bash provider (Linux only).

Never give the worker an XDG path: it sees private copies through inherited
directory FDs. Existing persistent files are opened no-follow, checked by fstat,
and bounded before copying. Only changed allowlisted files are published back.
"""
import contextlib
import fcntl
import os
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import time

DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
UID = os.geteuid()
STATE_LIMITS = {"omathlete.json": 262144, "omathlete-reminders.json": 32768}
DEFAULT = b'{"schemaVersion":1,"spoilersHidden":false,"sortMode":"manual","pinnedTeam":null,"teams":[]}\n'
MUTATIONS = {"add", "follow", "remove", "toggle-spoilers", "cycle-sort", "move",
             "toggle-pin", "watch-game", "remind-game", "toggle-quiet", "check-reminders"}
SPORT = r"(?:nfl|nba|wnba|mlb|nhl|cfb|cbb|epl|mls)"
MAX_FILES = 128
MAX_SNAPSHOT_FILES = 64  # leave room for new team/league/date outputs
MAX_SCAN = 4096
MAX_BYTES = 64 * 1024 * 1024


class UnsafeStorage(ValueError):
    pass


def check_directory(fd, *, owned=False):
    info = os.fstat(fd)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid not in ({UID} if owned else {0, UID}):
        raise UnsafeStorage("directory owner/type is unsafe")
    # Permit root-owned sticky /tmp as an ancestor, never as a storage leaf.
    sticky_root = not owned and info.st_uid == 0 and info.st_mode & stat.S_ISVTX
    if info.st_mode & 0o022 and not sticky_root:
        raise UnsafeStorage("directory is writable by another user/group")


def open_directory(path):
    if not path.startswith("/") or ".." in path.split("/"):
        raise UnsafeStorage("XDG storage must use absolute paths without '..'")
    fd = os.open("/", DIR_FLAGS)
    try:
        check_directory(fd)
        for part in filter(None, path.split("/")):
            try:
                child = os.open(part, DIR_FLAGS, dir_fd=fd)
            except FileNotFoundError:
                try:
                    os.mkdir(part, mode=0o700, dir_fd=fd)
                except FileExistsError:
                    pass
                child = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
            check_directory(fd)
        check_directory(fd, owned=True)
        return fd
    except BaseException:
        os.close(fd)
        raise


def check_file(info):
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != UID
            or info.st_nlink != 1 or info.st_mode & 0o022):
        raise UnsafeStorage("file owner/type/link count/permissions are unsafe")


def read_file(directory, name, limit):
    try:
        fd = os.open(name, FILE_FLAGS, dir_fd=directory)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        check_file(info)
        if info.st_size > limit:
            return None
        data = stream.read(limit + 1)
        if len(data) > limit:
            return None
        return data, info


def check_destination(directory, name):
    try:
        check_file(os.stat(name, dir_fd=directory, follow_symlinks=False))
    except FileNotFoundError:
        pass


def atomic_write(directory, name, data, timestamp=None):
    # Both rename endpoints are relative to the SAME held directory descriptor.
    # A destination replaced after inspection is replaced, never followed.
    check_directory(directory, owned=True)
    check_destination(directory, name)
    temporary = ".publish-" + secrets.token_hex(16)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                 | os.O_CLOEXEC, 0o600, dir_fd=directory)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            if timestamp is not None:
                os.utime(stream.fileno(), ns=(timestamp, timestamp))
            os.fsync(stream.fileno())
        check_destination(directory, name)
        os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
        os.fsync(directory)
    finally:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass


@contextlib.contextmanager
def state_lock(directory):
    fd = os.open(".omathlete.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW
                 | os.O_NONBLOCK | os.O_CLOEXEC, 0o600, dir_fd=directory)
    try:
        check_file(os.fstat(fd))
        deadline = time.monotonic() + 30
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise UnsafeStorage("settings lock timed out")
                time.sleep(0.025)
        yield
    finally:
        os.close(fd)


def cache_limit(name):
    if name == "teams.json":
        return 2 * 1024 * 1024
    if re.fullmatch(r"slate-" + SPORT + r"-[0-9]{8}\.json", name):
        return 512 * 1024
    if re.fullmatch(SPORT + r"-20[0-9]{2}\.json", name):
        return 8 * 1024 * 1024  # league season feed
    if re.fullmatch(SPORT + r"-[0-9]{1,12}\.json", name):
        return 64 * 1024
    return 0


def cache_names(directory, limit=MAX_FILES):
    names = []
    with os.scandir(directory) as entries:
        for count, entry in enumerate(entries):
            if count >= MAX_SCAN:
                raise UnsafeStorage("too many cache directory entries")
            if cache_limit(entry.name):
                info = entry.stat(follow_symlinks=False)
                check_file(info)
                names.append((info.st_mtime_ns, entry.name))
    return [name for _, name in sorted(names, reverse=True)[:limit]]


def snapshot(source, target, limits):
    baseline = {}
    total = 0
    for name, limit in limits.items():
        value = read_file(source, name, limit)
        if value is None:
            continue
        data, info = value
        total += len(data)
        if total > MAX_BYTES:
            raise UnsafeStorage("cache snapshot byte budget exceeded")
        atomic_write(target, name, data, info.st_mtime_ns)
        baseline[name] = (data, info.st_mtime_ns)
    return baseline


def publish(source, target, baseline, limits, *, delete=False):
    total = 0
    current_snapshot = {}
    for name, limit in limits.items():
        value = read_file(source, name, limit)
        old = baseline.get(name)
        if value is None:
            if delete and old is not None:
                current = read_file(target, name, limit)
                if current and (current[0], current[1].st_mtime_ns) == old:
                    os.unlink(name, dir_fd=target)  # unlink never follows a symlink
            continue
        data, info = value
        total += len(data)
        if total > MAX_BYTES:
            raise UnsafeStorage("publication byte budget exceeded")
        if old != (data, info.st_mtime_ns):
            atomic_write(target, name, data, info.st_mtime_ns)
        current_snapshot[name] = (data, info.st_mtime_ns)
    return current_snapshot


@contextlib.contextmanager
def staging(cache):
    name = ".work-" + secrets.token_hex(16)
    os.mkdir(name, mode=0o700, dir_fd=cache)
    with contextlib.ExitStack() as stack:
        root = os.open(name, DIR_FLAGS, dir_fd=cache)
        stack.callback(os.close, root)
        check_directory(root, owned=True)
        descriptors = []
        try:
            for child in ("state", "cache"):
                os.mkdir(child, mode=0o700, dir_fd=root)
                fd = os.open(child, DIR_FLAGS, dir_fd=root)
                stack.callback(os.close, fd)
                descriptors.append(fd)
            yield descriptors
        finally:
            # Python's fd-based rmtree does not follow replaced directory symlinks.
            for child in ("state", "cache"):
                shutil.rmtree(child, dir_fd=root)
            os.rmdir(name, dir_fd=cache)


def run(arguments):
    os.umask(0o077)
    home = os.environ.get("HOME", "")
    state_path = (os.environ.get("XDG_STATE_HOME") or home + "/.local/state") + "/omarchy/settings"
    cache_path = (os.environ.get("XDG_CACHE_HOME") or home + "/.cache") + "/omarchy/omathlete"
    mutable = bool(arguments and arguments[0] in MUTATIONS)
    with contextlib.ExitStack() as stack:
        state = open_directory(state_path)
        stack.callback(os.close, state)
        cache = open_directory(cache_path)
        stack.callback(os.close, cache)
        work_state, work_cache = stack.enter_context(staging(cache))
        # Mutations hold the lock through publication. Read-only/network commands
        # release it after taking a coherent settings snapshot.
        lock = state_lock(state)
        lock.__enter__()
        try:
            try:
                os.stat("omathlete.json", dir_fd=state, follow_symlinks=False)
            except FileNotFoundError:
                atomic_write(state, "omathlete.json", DEFAULT)
            state_before = snapshot(state, work_state, STATE_LIMITS)
            if "omathlete.json" not in state_before:
                atomic_write(work_state, "omathlete.json", b"{}\n")
                state_before["omathlete.json"] = (b"{}\n", os.stat(
                    "omathlete.json", dir_fd=work_state).st_mtime_ns)
        except BaseException:
            lock.__exit__(*sys.exc_info())
            raise
        if mutable:
            stack.callback(lock.__exit__, None, None, None)
        else:
            lock.__exit__(None, None, None)
        cache_before = snapshot(cache, work_cache,
                                {n: cache_limit(n) for n in cache_names(cache, MAX_SNAPSHOT_FILES)})
        def commit_cache():
            nonlocal cache_before
            names = set(cache_before) | set(cache_names(work_cache))
            if len(names) > MAX_FILES:
                raise UnsafeStorage("too many cache outputs")
            cache_before = publish(work_cache, cache, cache_before,
                                   {n: cache_limit(n) for n in names}, delete=mutable)
        worker = os.path.join(os.path.dirname(__file__), "provider.sh")
        streaming = bool(arguments and arguments[0] == "detail-stream")
        process = subprocess.Popen(["/usr/bin/bash", worker, str(work_state), str(work_cache), *arguments],
                                   pass_fds=(work_state, work_cache), start_new_session=True,
                                   stdout=subprocess.PIPE if streaming else None)
        def terminate(signum, _frame):
            try:
                os.killpg(process.pid, signum)
            except ProcessLookupError:
                pass
        previous = {s: signal.signal(s, terminate) for s in (signal.SIGTERM, signal.SIGINT)}
        try:
            if streaming:
                total = count = 0
                for line in iter(lambda: process.stdout.readline(1024 * 1024 + 1), b""):
                    total += len(line)
                    count += 1
                    if len(line) > 1024 * 1024 or total > 2 * 1024 * 1024 or count > 14:
                        raise UnsafeStorage("worker stream exceeds output budget")
                    # Make a newly displayed game available to watch/reminder
                    # commands before forwarding its row to the QML collector.
                    commit_cache()
                    sys.stdout.buffer.write(line)
                    sys.stdout.buffer.flush()
            result = process.wait()
        finally:
            if process.poll() is None:
                terminate(signal.SIGTERM, None)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    terminate(signal.SIGKILL, None)
                    process.wait()
            if process.stdout is not None:
                process.stdout.close()
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        if result == 0:
            if mutable:
                publish(work_state, state, state_before, STATE_LIMITS)
            commit_cache()
        return result if result >= 0 else 128 - result


if __name__ == "__main__":
    if sys.version_info < (3, 11):
        sys.exit("Omathlete storage requires Python 3.11 or newer.")
    try:
        sys.exit(run(sys.argv[1:]))
    except (OSError, UnsafeStorage) as error:
        print(f"Omathlete: unsafe or unavailable storage ({error}). No unsafe path was followed.", file=sys.stderr)
        sys.exit(1)
