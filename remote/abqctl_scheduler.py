#!/usr/bin/env python3
"""HPC-side nohup scheduler: lease + resource-aware job dispatch."""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

# local imports
sys.path.insert(0, str(Path(__file__).resolve().parent))
import abqctl_db as db  # noqa: E402
import abqctl_node_scan as scan  # noqa: E402

QUEUE_DIR = os.environ.get("ABQCTL_QUEUE_DIR", "/public/home/tsyg/tsyg/abqctl_queue")
NODES = os.environ.get("ABQCTL_NODES", "login05 login08 login10").split()
CPU_FACTOR = float(os.environ.get("ABQCTL_CPU_FACTOR", "0.8"))
MAX_JOBS_PER_NODE = int(os.environ.get("ABQCTL_MAX_JOBS_PER_NODE", "2"))
INTERVAL = int(os.environ.get("ABQCTL_SCHED_INTERVAL", "15"))
LEASE_SEC = int(os.environ.get("ABQCTL_LEASE_SEC", "45"))
STOP_FLAG = Path(QUEUE_DIR) / "scheduler.stop"
PID_FILE = Path(QUEUE_DIR) / "scheduler.pid"
LOG_PREFIX = "[scheduler]"

_owner = ""
_stop = False


def log(msg: str) -> None:
    print(f"{LOG_PREFIX} {msg}", flush=True)


def handle_signal(signum, frame) -> None:  # noqa: ARG001
    global _stop
    _stop = True
    log(f"signal {signum}; stopping")


def write_pid() -> None:
    Path(QUEUE_DIR).mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(os.getpid()), encoding="utf-8")


def clear_stop_flag() -> None:
    if STOP_FLAG.exists():
        STOP_FLAG.unlink()


def should_stop() -> bool:
    return _stop or STOP_FLAG.exists()


def gather_snapshots() -> list[dict]:
    me = scan.hostname()
    out = []
    for n in NODES:
        if n == me or n in me:
            snap = scan.scan_local()
        else:
            snap = scan.scan_remote(n)
        db.upsert_node_snapshot(snap, QUEUE_DIR)
        out.append(snap)
    return out


def free_cpus(snap: dict) -> float:
    ncpu = int(snap.get("ncpu") or 0)
    used = int(snap.get("used_cpus") or 0)
    return max(0.0, ncpu * CPU_FACTOR - used)


def pick_node(job: dict, snaps: list[dict]) -> str | None:
    prefer = job.get("prefer_node")
    need = int(job.get("cpus") or 8)
    candidates = []
    for s in snaps:
        if s.get("error"):
            continue
        node = s.get("node") or ""
        if prefer and prefer not in node and node != prefer:
            continue
        if int(s.get("running_jobs") or 0) >= MAX_JOBS_PER_NODE:
            continue
        if free_cpus(s) < need:
            continue
        candidates.append((free_cpus(s), node, s))
    if not candidates:
        # if prefer set and failed, do not fall back unless prefer empty
        if prefer:
            return None
        return None
    candidates.sort(key=lambda x: -x[0])
    return candidates[0][1]


def start_abaqus_on_node(job: dict, node: str) -> tuple[bool, str, int | None, str]:
    """Start via SSH to node (or local). Returns ok, message, pid, job_name."""
    inp = job["inp"]
    cpus = int(job["cpus"])
    double_mode = job.get("double_mode") or "both"
    job_name = Path(inp).stem
    me = scan.hostname()

    remote_cmd = f"""
set -e
source "$HOME/software/abaqus2020.env" 2>/dev/null || true
INP='{inp}'
test -r "$INP"
WD=$(dirname "$INP")
JOB='{job_name}'
CPUS={cpus}
DBL='{double_mode}'
cd "$WD"
mkdir -p scratch
rm -f "${{JOB}}.lck" 2>/dev/null || true
export OMP_NUM_THREADS=$CPUS OMP_DYNAMIC=FALSE
setsid nohup abaqus job="$JOB" input="$(basename "$INP")" \\
  cpus="$CPUS" mp_mode=threads double="$DBL" \\
  scratch="$WD/scratch" interactive \\
  > "run_${{JOB}}.log" 2>&1 < /dev/null &
echo $! > "run_${{JOB}}.pid"
echo STARTED:$JOB:$(cat "run_${{JOB}}.pid"):$(hostname)
"""

    if node == me or node in me:
        p = subprocess.run(
            ["bash", "-lc", remote_cmd],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=120,
            check=False,
        )
        out = p.stdout or ""
    else:
        p = subprocess.run(
            [
                "ssh",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=15",
                "-o",
                "StrictHostKeyChecking=no",
                node,
                "bash",
                "-lc",
                remote_cmd,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=120,
            check=False,
        )
        out = p.stdout or ""

    for line in out.splitlines():
        if line.startswith("STARTED:"):
            parts = line.strip().split(":")
            if len(parts) >= 3:
                try:
                    pid = int(parts[2])
                except ValueError:
                    pid = None
                return True, out[-800:], pid, job_name
    return False, out[-800:] or "start failed", None, job_name


def job_still_running(job: dict) -> bool:
    node = job.get("node") or ""
    name = job.get("job_name") or ""
    if not name:
        return False
    me = scan.hostname()
    check = (
        f"pgrep -af 'analysis.pyc -job {name}( |$)|job={name}( |$)|/{name}\\.com' >/dev/null"
    )
    if node == me or node in me:
        return subprocess.run(["bash", "-lc", check], check=False).returncode == 0
    r = subprocess.run(
        [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=8",
            "-o",
            "StrictHostKeyChecking=no",
            node,
            check,
        ],
        check=False,
    )
    return r.returncode == 0


def reclaim_finished() -> None:
    for job in db.list_running_tracked(QUEUE_DIR):
        try:
            if not job_still_running(job):
                log(f"job id={job['id']} name={job.get('job_name')} finished -> done")
                db.mark_done(job["id"], QUEUE_DIR)
        except Exception as e:
            log(f"reclaim error id={job.get('id')}: {e}")


def _revert_to_waiting(job_id: int, note: str) -> None:
    conn = db.connect(QUEUE_DIR)
    try:
        conn.execute(
            """
            UPDATE jobs SET status='waiting', updated_at=?, error=?
            WHERE id=? AND status='starting'
            """,
            (db.now_iso(), note[:500], job_id),
        )
        conn.commit()
    finally:
        conn.close()


def dispatch_one(snaps: list[dict]) -> bool:
    """FIFO: only claim head when a node currently fits; else wait next loop."""
    waiting = db.list_jobs(status="waiting", limit=1, queue_dir=QUEUE_DIR)
    if not waiting:
        return False
    head = waiting[0]
    node = pick_node(head, snaps)
    if not node:
        return False

    claimed = db.claim_next_job(QUEUE_DIR)
    if not claimed:
        return False
    # Head may have changed between peek and claim
    if claimed["id"] != head["id"]:
        node = pick_node(claimed, snaps)
        if not node:
            _revert_to_waiting(claimed["id"], "no node with enough free CPUs; waiting")
            return False

    log(f"starting id={claimed['id']} inp={claimed['inp']} cpus={claimed['cpus']} node={node}")
    ok, msg, pid, job_name = start_abaqus_on_node(claimed, node)
    if ok and pid:
        db.mark_running(claimed["id"], node, pid, job_name, QUEUE_DIR)
        log(f"running id={claimed['id']} pid={pid} job={job_name} node={node}")
        return True
    db.mark_failed(claimed["id"], msg or "start failed", QUEUE_DIR)
    log(f"failed id={claimed['id']}: {msg[:200]}")
    return False


def main() -> int:
    global _owner
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    db.init_db(QUEUE_DIR)
    write_pid()
    clear_stop_flag()
    host = scan.hostname()
    _owner = f"{host}:{os.getpid()}"

    if not db.lease_try_acquire(_owner, LEASE_SEC, QUEUE_DIR):
        st = db.lease_status(QUEUE_DIR)
        log(f"lease held by {st}; exit")
        return 0

    log(f"started owner={_owner} nodes={NODES} interval={INTERVAL}s")
    while not should_stop():
        if not db.lease_renew(_owner, LEASE_SEC, QUEUE_DIR):
            log("lost lease; exit")
            break
        try:
            db.requeue_stale_starting(120, QUEUE_DIR)
            snaps = gather_snapshots()
            reclaim_finished()
            # dispatch up to free slots (max 1 per loop by default for predictability)
            dispatch_one(snaps)
        except Exception as e:
            log(f"loop error: {e}")
        for _ in range(INTERVAL):
            if should_stop():
                break
            time.sleep(1)

    try:
        db.lease_release(_owner, QUEUE_DIR)
    except Exception:
        pass
    log("exited")
    return 0


if __name__ == "__main__":
    sys.exit(main())
