#!/usr/bin/env python3
"""SQLite helpers for abqctl_queue. Compatible with Python 3.6+."""
from __future__ import print_function

import argparse
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

DEFAULT_QUEUE_DIR = os.environ.get(
    "ABQCTL_QUEUE_DIR", "/public/home/tsyg/tsyg/abqctl_queue"
)


def _iso(dt):
    """Format datetime; avoid isoformat(timespec=) for older interpreters."""
    s = dt.isoformat()
    if "." in s:
        # trim microseconds but keep timezone offset
        head, rest = s.split(".", 1)
        m = re.search(r"([+-]\d{2}:\d{2}|Z)$", rest)
        if m:
            return head + m.group(1)
        return head
    return s


def now_iso():
    return _iso(datetime.now(timezone.utc).astimezone())


def parse_iso(s):
    """Parse ISO timestamps on Py3.6+ (fromisoformat is 3.7+)."""
    if s is None:
        raise ValueError("empty time")
    s = str(s).strip()
    if hasattr(datetime, "fromisoformat"):
        try:
            return datetime.fromisoformat(s)
        except Exception:
            pass
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    # "+08:00" -> "+0800" for strptime %z
    if len(s) >= 6 and s[-3] == ":" and s[-6] in "+-":
        s = s[:-3] + s[-2:]
    for fmt in (
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%dT%H:%M:%S.%f%z",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
    ):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            continue
    raise ValueError("bad time: " + s)


def db_path(queue_dir=None):
    root = Path(queue_dir or DEFAULT_QUEUE_DIR)
    root.mkdir(parents=True, exist_ok=True)
    return root / "queue.db"


def connect(queue_dir=None):
    path = db_path(queue_dir)
    conn = sqlite3.connect(str(path), timeout=60)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=60000")
    return conn


def init_db(queue_dir=None):
    root = Path(queue_dir or DEFAULT_QUEUE_DIR)
    root.mkdir(parents=True, exist_ok=True)
    schema = Path(__file__).resolve().parent / "schema.sql"
    sql = schema.read_text(encoding="utf-8")
    conn = connect(queue_dir)
    try:
        conn.executescript(sql)
        conn.commit()
    finally:
        conn.close()
    return str(db_path(queue_dir))


def enqueue(
    inp,
    cpus=8,
    double_mode="both",
    prefer_node=None,
    priority=0,
    queue_dir=None,
):
    init_db(queue_dir)
    ts = now_iso()
    conn = connect(queue_dir)
    try:
        cur = conn.execute(
            """
            INSERT INTO jobs (
              inp, cpus, double_mode, prefer_node, priority, status,
              created_at, updated_at, backend
            ) VALUES (?, ?, ?, ?, ?, 'waiting', ?, ?, 'direct')
            """,
            (
                inp,
                int(cpus),
                double_mode,
                prefer_node or None,
                int(priority),
                ts,
                ts,
            ),
        )
        conn.commit()
        return int(cur.lastrowid)
    finally:
        conn.close()


def list_jobs(status=None, limit=200, queue_dir=None):
    init_db(queue_dir)
    conn = connect(queue_dir)
    try:
        if status:
            rows = conn.execute(
                """
                SELECT * FROM jobs WHERE status = ?
                ORDER BY priority DESC, id ASC LIMIT ?
                """,
                (status, limit),
            ).fetchall()
        else:
            rows = conn.execute(
                """
                SELECT * FROM jobs
                ORDER BY
                  CASE status
                    WHEN 'running' THEN 0
                    WHEN 'starting' THEN 1
                    WHEN 'waiting' THEN 2
                    WHEN 'failed' THEN 3
                    WHEN 'done' THEN 4
                    ELSE 5
                  END,
                  priority DESC, id ASC
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def get_job(job_id, queue_dir=None):
    init_db(queue_dir)
    conn = connect(queue_dir)
    try:
        row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def cancel_job(job_id, queue_dir=None):
    """Cancel waiting or starting jobs (still in queue)."""
    init_db(queue_dir)
    ts = now_iso()
    conn = connect(queue_dir)
    try:
        cur = conn.execute(
            """
            UPDATE jobs SET status='cancelled', updated_at=?, finished_at=?
            WHERE id=? AND status IN ('waiting', 'starting')
            """,
            (ts, ts, job_id),
        )
        conn.commit()
        return cur.rowcount > 0
    finally:
        conn.close()


def stop_job(job_id, queue_dir=None):
    """
    Stop a queue job.
    waiting/starting -> cancelled (no kill needed)
    running -> mark cancelled and return node/job_name for process kill
    """
    init_db(queue_dir)
    ts = now_iso()
    conn = connect(queue_dir)
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        if not row:
            conn.commit()
            return {"ok": False, "id": job_id, "error": "not found"}
        job = dict(row)
        status = job.get("status") or ""
        if status in ("waiting", "starting"):
            conn.execute(
                """
                UPDATE jobs SET status='cancelled', updated_at=?, finished_at=?,
                  error=?
                WHERE id=? AND status IN ('waiting', 'starting')
                """,
                (ts, ts, "cancelled by user", job_id),
            )
            conn.commit()
            job["status"] = "cancelled"
            return {
                "ok": True,
                "id": job_id,
                "action": "cancelled",
                "prev_status": status,
                "job": job,
            }
        if status == "running":
            conn.execute(
                """
                UPDATE jobs SET status='cancelled', updated_at=?, finished_at=?,
                  error=?
                WHERE id=? AND status='running'
                """,
                (ts, ts, "stopped by user", job_id),
            )
            conn.commit()
            return {
                "ok": True,
                "id": job_id,
                "action": "kill",
                "prev_status": status,
                "node": job.get("node") or "",
                "job_name": job.get("job_name") or "",
                "pid": job.get("pid"),
                "job": job,
            }
        conn.commit()
        return {
            "ok": False,
            "id": job_id,
            "error": "cannot stop status=%s" % status,
            "status": status,
        }
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def delete_job(job_id, queue_dir=None):
    """Delete job row. Refuses if still running/starting (stop first)."""
    init_db(queue_dir)
    conn = connect(queue_dir)
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        if not row:
            conn.commit()
            return {"ok": False, "id": job_id, "error": "not found"}
        status = row["status"]
        if status in ("running", "starting"):
            conn.commit()
            return {
                "ok": False,
                "id": job_id,
                "error": "still %s; stop first" % status,
                "status": status,
            }
        conn.execute("DELETE FROM jobs WHERE id=?", (job_id,))
        conn.commit()
        return {"ok": True, "id": job_id, "action": "deleted", "prev_status": status}
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def claim_next_job(queue_dir=None):
    """Mark next waiting job as starting. Caller must hold scheduling lock."""
    ts = now_iso()
    conn = connect(queue_dir)
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            """
            SELECT * FROM jobs
            WHERE status='waiting'
            ORDER BY priority DESC, id ASC
            LIMIT 1
            """
        ).fetchone()
        if not row:
            conn.commit()
            return None
        conn.execute(
            """
            UPDATE jobs SET status='starting', updated_at=? WHERE id=?
            """,
            (ts, row["id"]),
        )
        conn.commit()
        out = dict(row)
        out["status"] = "starting"
        out["updated_at"] = ts
        return out
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def mark_running(job_id, node, pid, job_name, queue_dir=None):
    ts = now_iso()
    conn = connect(queue_dir)
    try:
        conn.execute(
            """
            UPDATE jobs SET status='running', node=?, pid=?, job_name=?,
              started_at=?, updated_at=?, error=NULL
            WHERE id=?
            """,
            (node, pid, job_name, ts, ts, job_id),
        )
        conn.commit()
    finally:
        conn.close()


def mark_failed(job_id, error, queue_dir=None):
    ts = now_iso()
    conn = connect(queue_dir)
    try:
        conn.execute(
            """
            UPDATE jobs SET status='failed', error=?, finished_at=?, updated_at=?
            WHERE id=?
            """,
            (error[:2000], ts, ts, job_id),
        )
        conn.commit()
    finally:
        conn.close()


def mark_done(job_id, queue_dir=None):
    ts = now_iso()
    conn = connect(queue_dir)
    try:
        conn.execute(
            """
            UPDATE jobs SET status='done', finished_at=?, updated_at=?
            WHERE id=?
            """,
            (ts, ts, job_id),
        )
        conn.commit()
    finally:
        conn.close()


def requeue_stale_starting(timeout_sec=120, queue_dir=None):
    conn = connect(queue_dir)
    try:
        rows = conn.execute(
            "SELECT id, updated_at FROM jobs WHERE status='starting'"
        ).fetchall()
        n = 0
        ts = now_iso()
        for r in rows:
            try:
                updated = parse_iso(r["updated_at"])
            except Exception:
                continue
            now = datetime.now(updated.tzinfo) if updated.tzinfo else datetime.now()
            if now - updated > timedelta(seconds=timeout_sec):
                conn.execute(
                    """
                    UPDATE jobs SET status='waiting', updated_at=?, error=?
                    WHERE id=? AND status='starting'
                    """,
                    (ts, "starting timeout; requeued", r["id"]),
                )
                n += 1
        conn.commit()
        return n
    finally:
        conn.close()


def list_running_tracked(queue_dir=None):
    return list_jobs(status="running", queue_dir=queue_dir)


def upsert_node_snapshot(snap, queue_dir=None):
    init_db(queue_dir)
    conn = connect(queue_dir)
    try:
        # Prefer UPSERT; fall back for very old SQLite
        try:
            conn.execute(
                """
                INSERT INTO node_snapshots(
                  node, ncpu, used_cpus, running_jobs, loadavg, detail_json, updated_at
                ) VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(node) DO UPDATE SET
                  ncpu=excluded.ncpu,
                  used_cpus=excluded.used_cpus,
                  running_jobs=excluded.running_jobs,
                  loadavg=excluded.loadavg,
                  detail_json=excluded.detail_json,
                  updated_at=excluded.updated_at
                """,
                (
                    snap["node"],
                    snap.get("ncpu"),
                    snap.get("used_cpus"),
                    snap.get("running_jobs"),
                    snap.get("loadavg"),
                    json.dumps(snap.get("jobs") or [], ensure_ascii=False),
                    now_iso(),
                ),
            )
        except sqlite3.OperationalError:
            conn.execute("DELETE FROM node_snapshots WHERE node=?", (snap["node"],))
            conn.execute(
                """
                INSERT INTO node_snapshots(
                  node, ncpu, used_cpus, running_jobs, loadavg, detail_json, updated_at
                ) VALUES (?,?,?,?,?,?,?)
                """,
                (
                    snap["node"],
                    snap.get("ncpu"),
                    snap.get("used_cpus"),
                    snap.get("running_jobs"),
                    snap.get("loadavg"),
                    json.dumps(snap.get("jobs") or [], ensure_ascii=False),
                    now_iso(),
                ),
            )
        conn.commit()
    finally:
        conn.close()


def list_node_snapshots(queue_dir=None):
    init_db(queue_dir)
    conn = connect(queue_dir)
    try:
        rows = conn.execute(
            "SELECT * FROM node_snapshots ORDER BY node"
        ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def lease_status(queue_dir=None):
    init_db(queue_dir)
    conn = connect(queue_dir)
    try:
        row = conn.execute(
            "SELECT * FROM scheduler_lease WHERE id=1"
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def lease_try_acquire(owner, lease_sec=45, queue_dir=None):
    """Acquire or steal expired lease. Returns True if this owner holds it."""
    init_db(queue_dir)
    ts = datetime.now(timezone.utc).astimezone()
    until = ts + timedelta(seconds=lease_sec)
    conn = connect(queue_dir)
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            "SELECT * FROM scheduler_lease WHERE id=1"
        ).fetchone()
        if row is None:
            conn.execute(
                """
                INSERT INTO scheduler_lease(id, owner, lease_until, heartbeat_at, started_at)
                VALUES (1, ?, ?, ?, ?)
                """,
                (owner, _iso(until), _iso(ts), _iso(ts)),
            )
            conn.commit()
            return True
        try:
            exp = parse_iso(row["lease_until"])
        except Exception:
            exp = ts
        if row["owner"] == owner or exp <= ts:
            conn.execute(
                """
                UPDATE scheduler_lease SET owner=?, lease_until=?, heartbeat_at=?,
                  started_at=CASE WHEN owner=? THEN started_at ELSE ? END
                WHERE id=1
                """,
                (owner, _iso(until), _iso(ts), owner, _iso(ts)),
            )
            conn.commit()
            return True
        conn.commit()
        return False
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def lease_renew(owner, lease_sec=45, queue_dir=None):
    init_db(queue_dir)
    ts = datetime.now(timezone.utc).astimezone()
    until = ts + timedelta(seconds=lease_sec)
    conn = connect(queue_dir)
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            "SELECT * FROM scheduler_lease WHERE id=1"
        ).fetchone()
        if not row or row["owner"] != owner:
            conn.commit()
            return False
        conn.execute(
            """
            UPDATE scheduler_lease SET lease_until=?, heartbeat_at=? WHERE id=1 AND owner=?
            """,
            (_iso(until), _iso(ts), owner),
        )
        conn.commit()
        return True
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def lease_release(owner, queue_dir=None):
    conn = connect(queue_dir)
    try:
        conn.execute(
            """
            UPDATE scheduler_lease SET lease_until=? WHERE id=1 AND owner=?
            """,
            (now_iso(), owner),
        )
        conn.commit()
    finally:
        conn.close()


def _print_json(obj):
    indent = 2 if isinstance(obj, list) and len(obj) > 1 else None
    print(json.dumps(obj, ensure_ascii=False, indent=indent))


def main(argv=None):
    p = argparse.ArgumentParser(description="abqctl_queue DB CLI")
    p.add_argument("--queue-dir", default=DEFAULT_QUEUE_DIR)
    sub = p.add_subparsers(dest="cmd")

    sub.add_parser("init")

    pe = sub.add_parser("enqueue")
    pe.add_argument("inp")
    pe.add_argument("--cpus", type=int, default=8)
    pe.add_argument("--double", default="both")
    pe.add_argument("--node", default="")
    pe.add_argument("--priority", type=int, default=0)

    pl = sub.add_parser("list")
    pl.add_argument("--status", default="")
    pl.add_argument("--limit", type=int, default=200)

    pc = sub.add_parser("cancel")
    pc.add_argument("id", type=int)

    ps = sub.add_parser("stop")
    ps.add_argument("id", type=int)

    pd = sub.add_parser("delete")
    pd.add_argument("id", type=int)

    pg = sub.add_parser("get")
    pg.add_argument("id", type=int)

    sub.add_parser("lease-status")
    sub.add_parser("nodes")

    args = p.parse_args(argv)
    if not args.cmd:
        p.print_help()
        return 2
    qd = args.queue_dir

    if args.cmd == "init":
        print(init_db(qd))
        return 0
    if args.cmd == "enqueue":
        jid = enqueue(
            args.inp,
            cpus=args.cpus,
            double_mode=args.double,
            prefer_node=args.node or None,
            priority=args.priority,
            queue_dir=qd,
        )
        print(json.dumps({"ok": True, "id": jid}, ensure_ascii=False))
        return 0
    if args.cmd == "list":
        rows = list_jobs(status=args.status or None, limit=args.limit, queue_dir=qd)
        _print_json(rows)
        return 0
    if args.cmd == "cancel":
        ok = cancel_job(args.id, queue_dir=qd)
        print(json.dumps({"ok": ok, "id": args.id}, ensure_ascii=False))
        return 0 if ok else 1
    if args.cmd == "stop":
        res = stop_job(args.id, queue_dir=qd)
        print(json.dumps(res, ensure_ascii=False))
        return 0 if res.get("ok") else 1
    if args.cmd == "delete":
        res = delete_job(args.id, queue_dir=qd)
        print(json.dumps(res, ensure_ascii=False))
        return 0 if res.get("ok") else 1
    if args.cmd == "get":
        row = get_job(args.id, queue_dir=qd)
        if not row:
            print(json.dumps({"ok": False, "id": args.id}, ensure_ascii=False))
            return 1
        print(json.dumps(row, ensure_ascii=False))
        return 0
    if args.cmd == "lease-status":
        st = lease_status(qd)
        _print_json(st or {"owner": None})
        return 0
    if args.cmd == "nodes":
        _print_json(list_node_snapshots(qd))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
