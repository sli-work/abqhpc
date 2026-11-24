#!/bin/bash
# abqctl — direct Abaqus runner (no sbatch/srun)
#
# Usage:
#   abqctl run <file.inp> [--cpus N] [--double both|explicit|off]
#   abqctl status [job_name|all]
#   abqctl log <job_name>
#   abqctl sta <job_name> [lines]
#   abqctl cancel <job_name>
#   abqctl list-inputs [dir]
#
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

job_name_from_inp() {
  basename "$1" .inp
}

find_job_dir() {
  local name=$1
  local cand
  # Prefer per-job subfolder <parent>/<job_name>/ (new layout).
  for cand in \
    "/public/home/tsyg/wh-data/hq/${name}" \
    "/public/home/tsyg/wh-data/${name}" \
    "/public/home/tsyg/tsyg/inputs/${name}" \
    "/public/home/tsyg/tsyg/${name}" \
    "/public/home/tsyg/wh-data/hq" \
    "/public/home/tsyg/wh-data" \
    "/public/home/tsyg/tsyg/inputs" \
    "/public/home/tsyg/tsyg"
  do
    if [[ -f "$cand/${name}.inp" || -f "$cand/${name}.lck" || -f "$cand/${name}.sta" || -f "$cand/run_${name}.log" ]]; then
      echo "$cand"
      return 0
    fi
  done
  local hit
  hit=$(find /public/home/tsyg -maxdepth 5 \( -name "${name}.sta" -o -name "${name}.lck" -o -name "run_${name}.log" \) 2>/dev/null | head -1 || true)
  if [[ -n "$hit" ]]; then
    dirname "$hit"
    return 0
  fi
  return 1
}

is_running() {
  local name=$1
  pgrep -af "analysis.pyc -job ${name}( |$)|job=${name}( |$)|/${name}\\.com" >/dev/null 2>&1
}

cmd_run() {
  [[ $# -ge 1 ]] || die "usage: abqctl run <file.inp> [--cpus N] [--double both]"
  local inp=$1; shift
  local cpus=8 double=both

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cpus) cpus=$2; shift 2 ;;
      --double) double=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done

  [[ -r "$inp" ]] || die "inp not readable: $inp"
  inp=$(readlink -f "$inp")
  local parent workdir job
  parent=$(dirname "$inp")
  job=$(job_name_from_inp "$inp")
  # Per-job folder: <parent>/<job>/ ; reuse if .inp already inside that folder.
  if [[ "$(basename "$parent")" == "$job" ]]; then
    workdir=$parent
  else
    workdir=$parent/$job
  fi

  source "$HOME/software/abaqus2020.env"
  command -v abaqus >/dev/null || die "abaqus not found"

  if is_running "$job"; then
    echo "WARN: job already running: $job"
    pgrep -af "analysis.pyc -job ${job}|/${job}\\.com" || true
    die "stop it first: abqctl cancel $job"
  fi

  mkdir -p "$workdir/scratch"
  if [[ "$inp" != "$workdir/${job}.inp" ]]; then
    ln -sfn "$inp" "$workdir/${job}.inp" 2>/dev/null || cp -f "$inp" "$workdir/${job}.inp"
  fi
  cd "$workdir"
  rm -f "${job}.lck" 2>/dev/null || true

  export OMP_NUM_THREADS=$cpus
  export OMP_DYNAMIC=FALSE

  # double is always passed through to abaqus as an explicit keyword argument
  case "$double" in
    both|explicit|off) ;;
    ""|none|no) double=both ;;
    *) die "bad --double=$double (use both|explicit|off)" ;;
  esac

  local log="$workdir/run_${job}.log"
  local pidfile="$workdir/run_${job}.pid"

  # Keep double=... on the abaqus command line (visible in ps / .com)
  setsid nohup abaqus job="$job" input="${job}.inp" \
    cpus="$cpus" mp_mode=threads \
    double="$double" \
    scratch="$workdir/scratch" \
    interactive \
    > "$log" 2>&1 < /dev/null &

  local pid=$!
  echo "$pid" > "$pidfile"
  sleep 3

  echo "started job=$job pid=$pid"
  echo "  workdir: $workdir"
  echo "  log:     $log"
  echo "  sta:     $workdir/${job}.sta"
  echo "  double:  $double  cpus=$cpus"
  echo "  host:    $(hostname)"
  echo
  if is_running "$job"; then
    echo "process:"
    pgrep -af "analysis.pyc -job ${job}|/${job}\\.com|eliT_DriverLM -job ${job}" | head -20 || true
  else
    echo "WARN: process not seen yet; log tail:"
    tr -d '\000' < "$log" | tail -n 40 || true
  fi
  echo
  echo "--- log ---"
  tr -d '\000' < "$log" | tail -n 40
}

cmd_status() {
  local arg=${1:-all}
  if [[ "$arg" == all ]]; then
    echo "=== running abaqus analyses ==="
    pgrep -af 'analysis.pyc -job |eliT_DriverLM -job |package_dp ' 2>/dev/null | grep -v 'pgrep\|abqctl' | head -40 || echo "(none)"
    echo
    echo "=== recent run logs ==="
    ls -lt /public/home/tsyg/wh-data/hq/run_*.log 2>/dev/null | head -15 || true
    return 0
  fi

  local job=$arg
  local workdir=""
  workdir=$(find_job_dir "$job" 2>/dev/null || true)
  echo "job=$job"
  if [[ -n "$workdir" ]]; then
    echo "workdir=$workdir"
  fi

  if is_running "$job"; then
    echo "state=RUNNING"
    pgrep -af "analysis.pyc -job ${job}|/${job}\\.com|eliT_DriverLM -job ${job}|package_dp .*${job}|pre -.*${job}" | head -20 || true
  else
    if [[ -n "$workdir" && -f "$workdir/${job}.lck" ]]; then
      echo "state=RUNNING_OR_LOCKED (has .lck)"
    elif [[ -n "$workdir" && -f "$workdir/${job}.sta" ]] && grep -Eiq 'THE ANALYSIS HAS COMPLETED SUCCESSFULLY' "$workdir/${job}.sta"; then
      echo "state=COMPLETED"
    else
      echo "state=NOT_RUNNING"
    fi
  fi

  if [[ -n "$workdir" ]]; then
    echo
    echo "=== files ==="
    ls -lah "$workdir/${job}".* "$workdir/run_${job}".* 2>/dev/null | head -40 || true
    echo
    echo "=== log tail ==="
    if [[ -f "$workdir/run_${job}.log" ]]; then
      tr -d '\000' < "$workdir/run_${job}.log" | tail -n 30
    fi
    echo
    echo "=== sta tail ==="
    if [[ -f "$workdir/${job}.sta" ]]; then
      tail -n 40 "$workdir/${job}.sta"
    else
      echo "(no .sta yet)"
    fi
  fi
}

cmd_log() {
  local job=${1:?usage: abqctl log <job_name>}
  local workdir
  workdir=$(find_job_dir "$job") || die "cannot locate job dir for $job"
  local log="$workdir/run_${job}.log"
  [[ -f "$log" ]] || die "missing log: $log"
  echo "log=$log"
  tr -d '\000' < "$log" | tail -n 100
}

cmd_sta() {
  local job=${1:?usage: abqctl sta <job_name> [lines]}
  local lines=${2:-100}
  local workdir
  workdir=$(find_job_dir "$job") || die "cannot locate job dir for $job"
  local sta="$workdir/${job}.sta"
  echo "workdir=$workdir"
  echo "sta=$sta"
  if [[ -f "$sta" ]]; then
    echo "=== $(date -Is) bytes=$(wc -c < "$sta") ==="
    tail -n "$lines" "$sta"
  else
    echo "(尚无 .sta，可能仍在 pre/package)"
    if [[ -f "$workdir/run_${job}.log" ]]; then
      echo "--- log ---"
      tr -d '\000' < "$workdir/run_${job}.log" | tail -n 40
    fi
  fi
}

cmd_cancel() {
  local job=${1:?usage: abqctl cancel <job_name>}
  echo "cancelling $job ..."
  pkill -f "analysis.pyc -job ${job}( |$)" 2>/dev/null || true
  pkill -f "/${job}\\.com" 2>/dev/null || true
  pkill -f "eliT_DriverLM -job ${job}( |$)" 2>/dev/null || true
  pkill -f "package_dp .* -job ${job}( |$)" 2>/dev/null || true
  pkill -f "pre -.* -job ${job}( |$)" 2>/dev/null || true
  sleep 1
  local workdir=""
  workdir=$(find_job_dir "$job" 2>/dev/null || true)
  if [[ -n "$workdir" ]]; then
    rm -f "$workdir/${job}.lck" 2>/dev/null || true
  fi
  if is_running "$job"; then
    echo "still running, force kill..."
    pkill -9 -f "analysis.pyc -job ${job}|/${job}\\.com|eliT_DriverLM -job ${job}" 2>/dev/null || true
    sleep 1
  fi
  if is_running "$job"; then
    echo "WARN: still alive:"
    pgrep -af "$job" || true
    exit 1
  fi
  echo "cancelled $job"
}

cmd_list_inputs() {
  local dir=${1:-/public/home/tsyg/wh-data/hq}
  ls -lah "$dir"/*.inp 2>/dev/null || echo "no inp in $dir"
}

usage() {
  sed -n '2,12p' "$0"
}

main() {
  local cmd=${1:-}
  shift || true
  case "$cmd" in
    run|submit) cmd_run "$@" ;;
    status) cmd_status "$@" ;;
    log) cmd_log "$@" ;;
    sta) cmd_sta "$@" ;;
    cancel) cmd_cancel "$@" ;;
    list-inputs) cmd_list_inputs "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
