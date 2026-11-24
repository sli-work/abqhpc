-- abqctl_queue schema (SQLite)
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  inp TEXT NOT NULL,
  cpus INTEGER NOT NULL DEFAULT 8,
  double_mode TEXT NOT NULL DEFAULT 'both',
  prefer_node TEXT,
  priority INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL,
  node TEXT,
  pid INTEGER,
  job_name TEXT,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  started_at TEXT,
  finished_at TEXT,
  backend TEXT NOT NULL DEFAULT 'direct'
);

CREATE INDEX IF NOT EXISTS idx_jobs_status_pri ON jobs(status, priority DESC, id ASC);

CREATE TABLE IF NOT EXISTS scheduler_lease (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  owner TEXT NOT NULL,
  lease_until TEXT NOT NULL,
  heartbeat_at TEXT NOT NULL,
  started_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS node_snapshots (
  node TEXT PRIMARY KEY,
  ncpu INTEGER,
  used_cpus INTEGER,
  running_jobs INTEGER,
  loadavg TEXT,
  detail_json TEXT,
  updated_at TEXT NOT NULL
);
