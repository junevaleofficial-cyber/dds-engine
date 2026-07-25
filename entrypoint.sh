#!/bin/bash
# DDS engine entrypoint — runs on every pod boot.
#
# ORDER IS DELIBERATE:
#   1. sshd FIRST, always, before anything can fail. If a gate later refuses to
#      start the engine we must still be able to log in and look. Exiting the
#      container would kill SSH and leave a black box.
#   2. Host-RAM gate SECOND, because it is the only failure that cannot be fixed
#      from inside the container.
set -u
COMFY_HOME=${COMFY_HOME:-/opt/ComfyUI}
VOL=${VOL:-/workspace}
STATUS=/var/log/dds_status

say() { echo "$*"; echo "$*" >> "$STATUS"; }
: > "$STATUS"

echo "==================== DDS ENGINE BOOT ===================="

# ---------------------------------------------------------------------------
# 1. SSH — this base image has no sshd. RunPod injects the key as $PUBLIC_KEY.
# ---------------------------------------------------------------------------
if [ -n "${PUBLIC_KEY:-}" ]; then
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi
ssh-keygen -A >/dev/null 2>&1
/usr/sbin/sshd -D -e >/var/log/sshd.log 2>&1 &
say "✅ sshd started (access is guaranteed even if a gate below refuses)"

# ---------------------------------------------------------------------------
# 2. GATE: HOST RAM — the #1 killer. Cost 2 dead pods on 2026-07-24.
#    `free` reports the HOST's memory and RunPod hosts are SHARED. A host with
#    ~2 GB free gets our engine SIGKILLed during model load even though our own
#    cgroup usage was 46 MB of a 61 GB limit — the kernel OOM killer does NOT
#    respect container limits. No flag, retry or code change survives it.
#    The ONLY fix is a different host.
#    A healthy host measured 150 GB free and ran 10/10 seeds flawlessly.
# ---------------------------------------------------------------------------
HOST_AVAIL=$(free -g | awk '/Mem:/{print $7}')
CG_GB="unknown"
for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
  if [ -f "$f" ]; then
    v=$(cat "$f" 2>/dev/null)
    case "$v" in ''|max) ;; *) CG_GB=$((v / 1073741824)); break;; esac
  fi
done
say "host available RAM : ${HOST_AVAIL} GB  (SHARED with other tenants)"
say "our cgroup limit   : ${CG_GB} GB"

if [ "${HOST_AVAIL:-0}" -lt 20 ] 2>/dev/null && [ "${DDS_SKIP_RAM_GATE:-0}" != "1" ]; then
  say "🔴 DDS_REFUSED_BAD_HOST"
  say "   Host has only ${HOST_AVAIL} GB free (need >=20). It is oversubscribed."
  say "   The engine WOULD be OOM-killed during model load regardless of flags."
  say "   ACTION: destroy this pod and create a new one (the volume is safe)."
  say "   sshd stays up so you can inspect. Set DDS_SKIP_RAM_GATE=1 to override."
  sleep infinity
fi
say "✅ GATE host-RAM OK"

# ---------------------------------------------------------------------------
# 3. GATE: port clear
# ---------------------------------------------------------------------------
if pgrep -f 'main.py --listen' >/dev/null 2>&1; then
  pkill -9 -f 'main.py --listen'; sleep 2
  say "⚠️  killed a pre-existing engine on :3000"
fi
say "✅ GATE port clear"

# ---------------------------------------------------------------------------
# 4. GATE: wire the volume. Code lives in the image; weights/outputs on volume.
# ---------------------------------------------------------------------------
if [ ! -d "$VOL/ComfyUI" ]; then
  say "🔴 DDS_REFUSED_NO_VOLUME — $VOL/ComfyUI not found. Attach network volume."
  sleep infinity
fi
for d in models input; do
  if [ -d "$VOL/ComfyUI/$d" ]; then
    rm -rf "$COMFY_HOME/$d"; ln -sfn "$VOL/ComfyUI/$d" "$COMFY_HOME/$d"
  else
    say "🔴 DDS_REFUSED_MISSING_DIR — $VOL/ComfyUI/$d"; sleep infinity
  fi
done
# Outputs go to the VOLUME, not container disk. Yesterday images landed on
# ephemeral disk and had to be raced off the pod before it died.
mkdir -p "$VOL/outputs"
rm -rf "$COMFY_HOME/output"; ln -sfn "$VOL/outputs" "$COMFY_HOME/output"
rm -f "$COMFY_HOME/user/comfyui.db.lock" 2>/dev/null
say "✅ GATE volume wired (output -> $VOL/outputs, survives the pod)"

# ---------------------------------------------------------------------------
# 5. GATE: weights present BEFORE boot, not after a failed render
# ---------------------------------------------------------------------------
MISSING=""
for f in models/checkpoints/RealVisXL_V5.0_fp16.safetensors \
         models/loras/breast_slider_sdxl.safetensors \
         models/controlnet/controlnet-union-sdxl-promax.safetensors \
         models/ultralytics/bbox/face_yolov8m.pt \
         models/insightface/models/antelopev2; do
  [ -e "$COMFY_HOME/$f" ] || MISSING="$MISSING $f"
done
if [ -n "$MISSING" ]; then
  say "🔴 DDS_REFUSED_MISSING_WEIGHTS:$MISSING"; sleep infinity
fi
say "✅ GATE weights present"

# ---------------------------------------------------------------------------
# 6. Launch. These flags are NOT optional: ComfyUI sizes its pinned-memory pool
#    from HOST RAM rather than the cgroup limit and OOM-kills itself.
#    Upstream: Comfy-Org/ComfyUI issues #11531 and #14250.
# ---------------------------------------------------------------------------
cd "$COMFY_HOME" || exit 1
say "DDS_READY_LAUNCHING"
echo "========================================================="
exec python main.py --listen --port 3000 \
     --disable-pinned-memory \
     --disable-async-offload \
     ${DDS_EXTRA_ARGS:-}
