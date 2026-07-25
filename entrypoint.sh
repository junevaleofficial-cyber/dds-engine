#!/bin/bash
# DDS engine entrypoint.
#
# HARD RULES LEARNED THE HARD WAY:
#  - This script must NEVER exit. If the entrypoint exits, the container dies,
#    which kills sshd, which makes the pod an unreadable black box. Every
#    failure path calls hold() -> sleep infinity instead of exit.
#  - Logs go to the VOLUME (/workspace/dds_boot.log), not /var/log. A log inside
#    a dying container cannot be read. A log on the volume survives the pod and
#    can be read from any later pod.
#  - sshd starts FIRST, before any check can fail.

COMFY_HOME=${COMFY_HOME:-/opt/ComfyUI}
VOL=${VOL:-/workspace}
LOG=/tmp/dds_boot.log
VLOG="$VOL/dds_boot.log"

log() {
  local m="[$(date -u +%H:%M:%S)] $*"
  echo "$m"                       # container stdout (RunPod log viewer)
  echo "$m" >> "$LOG" 2>/dev/null
  [ -d "$VOL" ] && echo "$m" >> "$VLOG" 2>/dev/null
}

hold() {
  log "🔴 $*"
  log "HELD: container kept alive on purpose so you can SSH in and inspect."
  log "      boot log: $VLOG (on the volume, survives this pod)"
  sleep infinity
}

: > "$LOG" 2>/dev/null
[ -d "$VOL" ] && : > "$VLOG" 2>/dev/null
log "==================== DDS ENGINE BOOT ===================="
log "image: dds-engine | whoami=$(whoami) | pwd=$(pwd)"

# ---------------------------------------------------------------------------
# 1. SSH FIRST — unconditionally, before anything can go wrong.
# ---------------------------------------------------------------------------
mkdir -p /root/.ssh /var/run/sshd 2>/dev/null
chmod 700 /root/.ssh 2>/dev/null
if [ -n "${PUBLIC_KEY:-}" ]; then
  printf '%s\n' "$PUBLIC_KEY" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  log "authorized_keys written ($(wc -l < /root/.ssh/authorized_keys) key lines)"
else
  log "⚠️  PUBLIC_KEY env is EMPTY — SSH key auth will not work"
fi
ssh-keygen -A >>"$LOG" 2>&1
# Daemonize (no -D). If it dies, the container must not.
/usr/sbin/sshd >>"$LOG" 2>&1
sleep 1
if pgrep -x sshd >/dev/null 2>&1; then
  log "✅ sshd listening on 22"
else
  log "⚠️  sshd FAILED to start — dumping config test:"
  /usr/sbin/sshd -t >>"$LOG" 2>&1
  tail -5 "$LOG" | while read -r l; do log "   $l"; done
fi

# ---------------------------------------------------------------------------
# 2. Locate python. This base ships conda at /opt/conda; if our ENTRYPOINT
#    bypasses their shell init, `python` may not be on PATH.
# ---------------------------------------------------------------------------
PY=""
for c in /opt/conda/bin/python python3 python /usr/bin/python3; do
  if command -v "$c" >/dev/null 2>&1; then PY=$(command -v "$c"); break; fi
done
[ -z "$PY" ] && hold "no python interpreter found on PATH=$PATH"
log "python: $PY ($($PY -V 2>&1))"
export PATH="$(dirname "$PY"):$PATH"

# ---------------------------------------------------------------------------
# 3. GATE: HOST RAM — the #1 killer (2 pods lost 2026-07-24).
#    `free` reports the HOST's memory; RunPod hosts are SHARED. A host with
#    ~2 GB free gets our engine SIGKILLed during model load even though our own
#    cgroup usage was 46 MB of a 61 GB limit — the kernel OOM killer does NOT
#    respect container limits. No flag or retry survives it. Only a new host.
# ---------------------------------------------------------------------------
HOST_AVAIL=$(free -g 2>/dev/null | awk '/^Mem:/{print $7}')
case "$HOST_AVAIL" in ''|*[!0-9]*) HOST_AVAIL=-1;; esac
CG_GB="unknown"
for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
  if [ -r "$f" ]; then
    v=$(cat "$f" 2>/dev/null)
    case "$v" in ''|max|*[!0-9]*) ;; *) CG_GB=$((v/1073741824)); break;; esac
  fi
done
log "host available RAM: ${HOST_AVAIL} GB (SHARED) | our cgroup limit: ${CG_GB} GB"
if [ "$HOST_AVAIL" -ge 0 ] && [ "$HOST_AVAIL" -lt 20 ] && [ "${DDS_SKIP_RAM_GATE:-0}" != "1" ]; then
  hold "DDS_REFUSED_BAD_HOST — only ${HOST_AVAIL} GB free (need >=20). This host is oversubscribed; the engine WOULD be OOM-killed during model load. DESTROY THIS POD AND CREATE A NEW ONE (the volume is safe). Override: DDS_SKIP_RAM_GATE=1"
fi
log "✅ GATE host-RAM"

# ---------------------------------------------------------------------------
# 4. GATE: volume wired
# ---------------------------------------------------------------------------
[ -d "$VOL/ComfyUI" ] || hold "DDS_REFUSED_NO_VOLUME — $VOL/ComfyUI missing. Attach network volume wmennpoi9z at /workspace."
for d in models input; do
  [ -d "$VOL/ComfyUI/$d" ] || hold "DDS_REFUSED_MISSING_DIR — $VOL/ComfyUI/$d"
  rm -rf "$COMFY_HOME/$d" 2>/dev/null
  ln -sfn "$VOL/ComfyUI/$d" "$COMFY_HOME/$d"
done
mkdir -p "$VOL/outputs" 2>/dev/null
rm -rf "$COMFY_HOME/output" 2>/dev/null
ln -sfn "$VOL/outputs" "$COMFY_HOME/output"
mkdir -p "$COMFY_HOME/user" 2>/dev/null
rm -f "$COMFY_HOME/user/comfyui.db.lock" 2>/dev/null
log "✅ GATE volume wired (output -> $VOL/outputs, survives the pod)"

# ---------------------------------------------------------------------------
# 5. GATE: weights present BEFORE boot, not after a wasted render
# ---------------------------------------------------------------------------
MISSING=""
for f in models/checkpoints/RealVisXL_V5.0_fp16.safetensors \
         models/loras/breast_slider_sdxl.safetensors \
         models/controlnet/controlnet-union-sdxl-promax.safetensors \
         models/ultralytics/bbox/face_yolov8m.pt \
         models/insightface/models/antelopev2; do
  [ -e "$COMFY_HOME/$f" ] || MISSING="$MISSING $f"
done
[ -n "$MISSING" ] && hold "DDS_REFUSED_MISSING_WEIGHTS:$MISSING"
log "✅ GATE weights present"

# ---------------------------------------------------------------------------
# 6. Launch. Flags are NOT optional — ComfyUI sizes its pinned-memory pool from
#    HOST RAM rather than the cgroup limit and OOM-kills itself.
#    Upstream: Comfy-Org/ComfyUI issues #11531, #14250.
#    Engine runs in BACKGROUND and we wait, so a crash logs a marker and holds
#    instead of taking the container (and sshd) down with it.
# ---------------------------------------------------------------------------
cd "$COMFY_HOME" || hold "cannot cd $COMFY_HOME"
log "DDS_LAUNCHING engine"
"$PY" main.py --listen --port 3000 \
      --disable-pinned-memory --disable-async-offload \
      ${DDS_EXTRA_ARGS:-} >> "$LOG" 2>&1 &
EPID=$!
echo "$EPID" > /tmp/dds_engine.pid
log "engine pid $EPID"

for i in $(seq 1 180); do
  if curl -s -m 5 http://127.0.0.1:3000/system_stats >/dev/null 2>&1; then
    log "✅ DDS_READY — API up after ~$((i*5))s"
    break
  fi
  kill -0 "$EPID" 2>/dev/null || { tail -40 "$LOG" >> "$VLOG" 2>/dev/null; hold "DDS_ENGINE_DIED during startup — last 40 log lines appended to $VLOG"; }
  sleep 5
done

wait "$EPID"
RC=$?
tail -40 "$LOG" >> "$VLOG" 2>/dev/null
hold "DDS_ENGINE_EXITED rc=$RC — see $VLOG"
