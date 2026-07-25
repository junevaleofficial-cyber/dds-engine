#!/bin/bash
# DDS engine entrypoint. Runs on every pod boot.
# Order matters: the host-RAM check comes FIRST because it is the only failure
# that cannot be fixed from inside the container.
set -u
COMFY_HOME=${COMFY_HOME:-/opt/ComfyUI}
VOL=${VOL:-/workspace}

echo "=================== DDS ENGINE BOOT ==================="

# ---------------------------------------------------------------------------
# GATE 1 — HOST RAM. The #1 killer (2026-07-24: two pods lost to this).
# `free` reports the HOST's memory and RunPod hosts are SHARED. A host with
# ~2 GB free will get our engine SIGKILLed by the host OOM killer during model
# load even though our own cgroup usage is ~46 MB of a 42-61 GB limit — the
# kernel OOM killer does NOT respect container limits. There is no flag, no
# retry and no code change that survives this. The only fix is a different host.
# ---------------------------------------------------------------------------
HOST_AVAIL=$(free -g | awk '/Mem:/{print $7}')
CG=""
for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
  [ -f "$f" ] && CG=$(cat "$f" 2>/dev/null) && break
done
[ -n "$CG" ] && [ "$CG" != "max" ] && CG_GB=$((CG / 1073741824)) || CG_GB="unknown"

echo "HOST available RAM : ${HOST_AVAIL} GB   (shared with other tenants)"
echo "OUR cgroup limit   : ${CG_GB} GB"

if [ "${HOST_AVAIL:-0}" -lt 20 ] 2>/dev/null; then
  echo ""
  echo "🔴 REFUSING TO START — host has only ${HOST_AVAIL} GB free (need >=20 GB)."
  echo "   This host is oversubscribed. The engine WILL be OOM-killed during"
  echo "   model load regardless of flags. DESTROY THIS POD AND CREATE A NEW ONE."
  echo "   (Set DDS_SKIP_RAM_GATE=1 to override, but expect a SIGKILL.)"
  [ "${DDS_SKIP_RAM_GATE:-0}" != "1" ] && exit 90
  echo "   DDS_SKIP_RAM_GATE=1 set — proceeding against advice."
fi
echo "✅ GATE 1 host RAM OK"

# ---------------------------------------------------------------------------
# GATE 2 — no stock engine squatting on the port.
# ---------------------------------------------------------------------------
if pgrep -f 'main.py --listen' >/dev/null 2>&1; then
  echo "⚠️  killing a pre-existing engine on :3000"
  pkill -9 -f 'main.py --listen'; sleep 2
fi
echo "✅ GATE 2 port clear"

# ---------------------------------------------------------------------------
# GATE 3 — wire the volume in. Models/outputs live there, code lives in the image.
# ---------------------------------------------------------------------------
if [ ! -d "$VOL" ]; then
  echo "🔴 $VOL not mounted — attach the network volume."; exit 91
fi
for d in models input; do
  if [ -d "$VOL/ComfyUI/$d" ]; then
    rm -rf "$COMFY_HOME/$d"; ln -sfn "$VOL/ComfyUI/$d" "$COMFY_HOME/$d"
    echo "   linked $d -> $VOL/ComfyUI/$d"
  else
    echo "🔴 missing $VOL/ComfyUI/$d"; exit 92
  fi
done
mkdir -p "$VOL/outputs"
rm -rf "$COMFY_HOME/output"; ln -sfn "$VOL/outputs" "$COMFY_HOME/output"
echo "   output -> $VOL/outputs   (persists across pods — no scp race)"
rm -f "$COMFY_HOME/user/comfyui.db.lock" 2>/dev/null
echo "✅ GATE 3 volume wired"

# ---------------------------------------------------------------------------
# GATE 4 — required weights present BEFORE we boot, not after a failed render.
# ---------------------------------------------------------------------------
MISSING=""
for f in models/checkpoints/RealVisXL_V5.0_fp16.safetensors \
         models/loras/breast_slider_sdxl.safetensors \
         models/controlnet/controlnet-union-sdxl-promax.safetensors \
         models/ultralytics/bbox/face_yolov8m.pt \
         models/insightface/models/antelopev2; do
  [ -e "$COMFY_HOME/$f" ] || MISSING="$MISSING $f"
done
if [ -n "$MISSING" ]; then echo "🔴 missing weights:$MISSING"; exit 93; fi
echo "✅ GATE 4 all weights present"

# ---------------------------------------------------------------------------
# Launch. The two flags are NOT optional — ComfyUI sizes its pinned-memory pool
# from HOST RAM, not the cgroup limit, and OOM-kills itself.
# Upstream: Comfy-Org/ComfyUI issues #11531 and #14250.
# ---------------------------------------------------------------------------
cd "$COMFY_HOME" || exit 1
echo "▶ launching engine (pinned memory + async offload DISABLED)"
echo "======================================================="
exec python main.py --listen --port 3000 \
     --disable-pinned-memory \
     --disable-async-offload \
     ${DDS_EXTRA_ARGS:-}
