#!/usr/bin/env python3
"""board_run -- one command to put a bitstream on the board, run a script and
bring the log back.

Every board experiment in this directory was a hand-written shell pipeline, and
three separate cycles lost time to the same class of mistake. This script exists
because each of those is cheap to prevent once and expensive to rediscover:

* **A stale log read as a fresh result.** `/tmp` on this board is tmpfs and the
  reboot at the end of a run wipes it -- taking the runner script with it, so a
  second run silently never executes while `/mnt/jffs2` still holds the first
  run's log. Every run now embeds a unique marker and the log is rejected unless
  it carries that run's marker.

* **A check that could not fail correctly.** The transfer probe was
  `busybox stat -c %s FILE || echo missing`; this busybox does not implement
  `-c`, so `stat` failed, printed nothing, and the fallback reported a missing
  file that was present and complete. Four rounds went into diagnosing a
  transfer that had succeeded. Sizes come from `ls -la` here.

* **Too many connections.** dropbear rate-limits authentication and refuses
  concurrent sessions; polling the board during a transfer makes both fail. One
  multiplexed connection does everything.

* **A watchdog that fires into a reboot.** The watchdog existed because a script
  that unbinds the network cannot report failure; it slept a fixed time and then
  forced a reboot regardless. When the run finished early and rebooted itself,
  the watchdog could land during the boot that followed. The watchdog now checks
  for a completion flag first, and reboots gracefully rather than with -f:
  twenty-odd forced reboots skip the unmount entirely, which is hard on a flash
  filesystem and is the most likely reason this board eventually stopped coming
  back at all.

Usage:
    ./board_run.py --bit build/x.swab.bin --script run.sh --log /mnt/jffs2/x.log
    ./board_run.py --bit ... --script ... --log ... --wait 180
"""

import argparse
import os
import subprocess
import sys
import time

HOST = os.environ.get("PLUTO_HOST", "192.168.1.10")
PASS = os.environ.get("PLUTO_PASS", "analog")
CTL = "/tmp/pluto_cm_run"

SSH_OPTS = [
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "GlobalKnownHostsFile=/dev/null",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "ControlMaster=auto", "-o", f"ControlPath={CTL}",
    "-o", "ControlPersist=10m", "-o", "ConnectTimeout=15",
    "-o", "NumberOfPasswordPrompts=1", "-o", "LogLevel=ERROR",
]

NOISE = ("post-quantum", "store now", "need to be upgraded", "openssh.com",
         "Permanently added", "Warning:")


def _clean(text):
    return "\n".join(l for l in text.splitlines()
                     if not any(n in l for n in NOISE))


def ssh(cmd, timeout=120):
    r = subprocess.run(["sshpass", "-p", PASS, "ssh"] + SSH_OPTS +
                       [f"root@{HOST}", cmd],
                       capture_output=True, text=True, timeout=timeout)
    return _clean(r.stdout), _clean(r.stderr), r.returncode


def scp(local, remote, timeout=300):
    r = subprocess.run(["sshpass", "-p", PASS, "scp", "-O"] + SSH_OPTS +
                       [local, f"root@{HOST}:{remote}"],
                       capture_output=True, text=True, timeout=timeout)
    return r.returncode


def remote_size(path):
    """ls -la, not stat -c: this busybox has no -c and fails silently."""
    out, _, _ = ssh(f"ls -la {path} 2>/dev/null")
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[-1].endswith(os.path.basename(path)):
            try:
                return int(parts[4])
            except ValueError:
                pass
    return None


def drop():
    subprocess.run(["ssh", "-o", f"ControlPath={CTL}", "-O", "exit",
                    f"root@{HOST}"], capture_output=True)


def wait_up(seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        r = subprocess.run(["ping", "-c1", "-W", "800", HOST],
                           capture_output=True)
        if r.returncode == 0:
            return True
        time.sleep(4)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bit", help="bitstream (.swab.bin) to copy to /tmp")
    ap.add_argument("--script", required=True, help="shell script to run")
    ap.add_argument("--log", required=True, help="log path on the board")
    ap.add_argument("--wait", type=int, default=170,
                    help="seconds to wait after launch before reconnecting")
    ap.add_argument("--watchdog", type=int, default=260)
    ap.add_argument("--marker", default=None)
    a = ap.parse_args()

    marker = a.marker or f"RUN-{os.getpid()}-{int(os.path.getmtime(a.script))}"
    print(f"marker: {marker}")

    out, err, rc = ssh("echo up")
    if "up" not in out:
        print(f"board not reachable: {err.strip()}")
        return 1

    if a.bit:
        want = os.path.getsize(a.bit)
        for attempt in range(1, 4):
            scp(a.bit, "/tmp/")
            got = remote_size("/tmp/" + os.path.basename(a.bit))
            print(f"  transfer attempt {attempt}: {got} of {want}")
            if got == want:
                break
        else:
            print("transfer never completed")
            return 1

    # Reboot policy lives here, not in the run scripts. A script that reboots
    # itself cannot also leave a completion flag afterwards -- the first version
    # of this appended the flag after the body and it was never reached.
    body = "\n".join(l for l in open(a.script).read().splitlines()
                     if l.strip() not in ("reboot", "reboot -f",
                                          "sync; sleep 2; reboot",
                                          "sync; sleep 2; reboot -f"))
    payload = (f"#!/bin/sh\necho '{marker}' > {a.log}\n"
               f"sync\n" + body +
               "\ntouch /tmp/board_run.done\nsync\nsleep 2\nreboot\n")
    ssh(f"rm -f {a.log}")
    p = subprocess.run(["sshpass", "-p", PASS, "ssh"] + SSH_OPTS +
                       [f"root@{HOST}", "cat > /tmp/board_run.sh"],
                       input=payload, capture_output=True, text=True)
    if p.returncode != 0:
        print("could not write the runner")
        return 1
    ssh("chmod +x /tmp/board_run.sh")

    # The watchdog stands down if the run left its flag, and reboots gracefully.
    ssh("rm -f /tmp/board_run.done")
    ssh(f'setsid sh -c "sleep {a.watchdog}; '
        f'[ -f /tmp/board_run.done ] || {{ sync; reboot; }}" '
        f'</dev/null >/dev/null 2>&1 & '
        f'setsid /tmp/board_run.sh </dev/null >/dev/null 2>&1 & echo LAUNCHED')
    print("launched")
    drop()
    time.sleep(a.wait)
    if not wait_up(90):
        print("board did not come back")
        return 1
    time.sleep(12)

    for attempt in range(1, 6):
        out, _, _ = ssh(f"cat {a.log} 2>/dev/null")
        if marker in out:
            print(out)
            return 0
        print(f"  (log not this run's yet, attempt {attempt})")
        time.sleep(25)
    print("log never carried this run's marker -- the run did not happen, and "
          "whatever is in the log belongs to an earlier one")
    return 1


if __name__ == "__main__":
    sys.exit(main())
