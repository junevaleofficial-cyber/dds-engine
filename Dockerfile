# DDS Engine — immutable ComfyUI image for RunPod
#
# Exists because rebuilding the engine on every pod boot cost ~35 min and caused
# 4 separate failures on 2026-07-24. Everything here is pinned. Nothing is
# installed at runtime.
#
# Deliberate choices, each fixing a real failure:
#  - Base is a PLAIN pytorch image, NOT runpod/stable-diffusion:comfy-ui-*.
#    That image auto-starts its own stock ComfyUI on :3000 with only the 5
#    default checkpoints and hijacked us on EVERY pod, fresh or resumed.
#  - Only the 4 custom nodes we actually call. Florence2/PuLID/InstantID/WD14
#    cost ~56s of import time and were never referenced.
#  - insightface installed EXPLICITLY. ComfyUI_IPAdapter_plus has no
#    requirements.txt, so insightface only ever arrived as a side-effect of
#    InstantID/PuLID. Dropping those broke every FaceID render with
#    "insightface model is required for FaceID models".
#  - git+/URL deps are never resolved by pip. PEP-517 build isolation spawns a
#    nested pip that re-downloads torch with --ignore-installed and IGNORES
#    constraints. sam2 in Impact-Pack hung a build for 22 minutes this way.
#  - Models are NOT baked in. They live on the network volume; baking ~12 GB of
#    weights would make image pulls worse than the problem being solved.

FROM runpod/pytorch:2.6.0-py3.11-cuda12.4.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONPYCACHEPREFIX=/tmp/pyc \
    COMFY_HOME=/opt/ComfyUI

# Pin the CUDA stack. A custom-node dep must never drag torch off this build.
COPY constraints.txt /opt/constraints.txt

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates libgl1 libglib2.0-0 bc \
    && rm -rf /var/lib/apt/lists/*

# ---- ComfyUI at a fixed ref ----
ARG COMFY_REF=master
RUN git clone https://github.com/comfyanonymous/ComfyUI.git $COMFY_HOME \
    && cd $COMFY_HOME \
    && git checkout $COMFY_REF \
    && pip install -c /opt/constraints.txt -r requirements.txt

# ---- ONLY the custom nodes we call ----
# IPAdapter_plus        -> IPAdapterUnifiedLoaderFaceID, IPAdapterFaceID
# Impact-Pack           -> FaceDetailer
# Impact-Subpack        -> UltralyticsDetectorProvider
# comfyui_controlnet_aux-> OpenposePreprocessor (pose-source extraction)
WORKDIR $COMFY_HOME/custom_nodes
RUN git clone https://github.com/cubiq/ComfyUI_IPAdapter_plus.git \
 && git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack.git \
 && git clone https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git \
 && git clone https://github.com/Fannovel16/comfyui_controlnet_aux.git

# Install node deps with git+/URL lines STRIPPED (see header note on sam2).
RUN set -eux; \
    for d in */ ; do \
      r="$d/requirements.txt"; \
      [ -f "$r" ] || continue; \
      echo "=== deps: $d (stripping $(grep -cE '^[[:space:]]*(git\+|https?://|-e )' "$r" || true) git/url lines)"; \
      grep -vE '^[[:space:]]*(git\+|https?://|-e )' "$r" \
        | grep -vE '^[[:space:]]*(#|$)' > /tmp/req.txt; \
      pip install -c /opt/constraints.txt -r /tmp/req.txt; \
    done

# ---- The orphan dependency. Never remove this line. ----
RUN pip install -c /opt/constraints.txt insightface onnxruntime-gpu

# ---- Prove the build is sound at BUILD time, not at 2am on a pod ----
RUN cd $COMFY_HOME && python -c "\
import comfy.ldm.models, insightface, torch, onnxruntime; \
assert torch.__version__.startswith('2.6.0'), torch.__version__; \
print('BUILD_VERIFY_OK torch', torch.__version__, 'insightface', insightface.__version__)"

COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh

WORKDIR $COMFY_HOME
EXPOSE 3000
ENTRYPOINT ["/opt/entrypoint.sh"]
