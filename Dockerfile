# DDS Engine — immutable ComfyUI image for RunPod
#
# GOAL: fast first boot, no runtime installs, no recurring errors.
#
# WHY THIS BASE (measured 2026-07-25, Docker Hub API):
#   runpod/stable-diffusion:comfy-ui-6.0.0        41.8 GB   <- what we used before
#   runpod/pytorch (current tags)                 10-12 GB  <- cu128/torch2.8, WRONG stack
#   pytorch/pytorch:2.6.0-cuda12.4-cudnn9-runtime  3.1 GB   <- EXACTLY our proven stack
# Built out this lands ~5-6 GB, roughly 7x smaller than the old image, and
# nothing is installed at boot. At the ~87 MB/s pull rate measured on RunPod
# yesterday that is ~70s of pull vs 8 min before.
#
# Each decision below fixes a REAL failure from 2026-07-24:
#  - Plain base, not a ComfyUI image: the stock template auto-started its own
#    ComfyUI on :3000 with only 5 default checkpoints and hijacked EVERY pod.
#  - Only the 4 custom nodes we call: Florence2/PuLID/InstantID/WD14 cost ~56s
#    of import time and were never referenced by any workflow.
#  - insightface installed EXPLICITLY: ComfyUI_IPAdapter_plus ships NO
#    requirements.txt, so insightface only ever arrived as a side-effect of
#    InstantID/PuLID. Pruning those broke every FaceID render with
#    "insightface model is required for FaceID models" - and the failure looked
#    like a silent no-op (prompt "succeeded" in 0.6s returning []).
#  - git+/URL deps never resolved by pip: PEP-517 build isolation spawns a
#    nested pip that re-downloads torch with --ignore-installed and IGNORES the
#    constraints file. sam2 in Impact-Pack hung a build 22 minutes this way.
#  - Models NOT baked in: they live on the network volume. Baking ~12 GB of
#    weights would make the pull worse than the problem being solved.

FROM pytorch/pytorch:2.6.0-cuda12.4-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONPYCACHEPREFIX=/tmp/pyc \
    COMFY_HOME=/opt/ComfyUI \
    CC=gcc \
    CXX=g++

COPY constraints.txt /opt/constraints.txt

# openssh-server: this base has no sshd, and RunPod access depends on it.
# procps: pgrep/pkill are used by the entrypoint gates.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates openssh-server procps \
        gcc g++ \
        libgl1 libglib2.0-0 \
    && mkdir -p /var/run/sshd /root/.ssh \
    && chmod 700 /root/.ssh \
    && sed -i 's/#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config \
    && sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && rm -rf /var/lib/apt/lists/*

# ---- ComfyUI ----
# TODO pin to a verified commit SHA once this image is proven end-to-end.
# 'master' is reproducible only per-build-date, which is weaker than we want.
ARG COMFY_REF=master
RUN git clone https://github.com/comfyanonymous/ComfyUI.git $COMFY_HOME \
    && cd $COMFY_HOME && git checkout $COMFY_REF \
    && pip install -c /opt/constraints.txt -r requirements.txt

# ---- ONLY the nodes our workflows actually call ----
# IPAdapter_plus         -> IPAdapterUnifiedLoaderFaceID, IPAdapterFaceID
# Impact-Pack            -> FaceDetailer
# Impact-Subpack         -> UltralyticsDetectorProvider
# comfyui_controlnet_aux -> OpenposePreprocessor (pose-source extraction)
# (SetUnionControlNetType, ControlNetLoader, LoraLoader are CORE ComfyUI.)
WORKDIR $COMFY_HOME/custom_nodes
RUN git clone --depth 1 https://github.com/cubiq/ComfyUI_IPAdapter_plus.git \
 && git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Impact-Pack.git \
 && git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git \
 && git clone --depth 1 https://github.com/Fannovel16/comfyui_controlnet_aux.git

RUN set -eux; \
    for d in */ ; do \
      r="$d/requirements.txt"; [ -f "$r" ] || continue; \
      echo "=== deps: $d (stripping $(grep -cE '^[[:space:]]*(git\+|https?://|-e )' "$r" || true) git/url lines)"; \
      grep -vE '^[[:space:]]*(git\+|https?://|-e )' "$r" | grep -vE '^[[:space:]]*(#|$)' > /tmp/req.txt; \
      pip install -c /opt/constraints.txt -r /tmp/req.txt; \
    done

# ---- THE ORPHAN DEPENDENCY. NEVER REMOVE THIS LINE. ----
# Nothing declares insightface, but FaceID cannot work without it.
RUN pip install -c /opt/constraints.txt insightface onnxruntime-gpu

# ---- LoRA TRAINER (kohya sd-scripts) ----
# Added 2026-07-26 for B4: the image was ComfyUI-only, so there was no way to
# train a LoRA on the pod at all. Same git+/URL stripping as the custom nodes:
# sd-scripts' requirements.txt ends in '-e .', and PEP-517 build isolation would
# spawn a nested pip that re-downloads torch with --ignore-installed, bypassing
# the constraints file (this is what hung a build for 22 minutes on sam2).
# We run the training scripts from their own directory, so '-e .' is not needed.
ARG SD_SCRIPTS_REF=main
RUN git clone https://github.com/kohya-ss/sd-scripts.git /opt/sd-scripts \
    && cd /opt/sd-scripts && git checkout $SD_SCRIPTS_REF \
    && grep -vE '^[[:space:]]*(git\+|https?://|-e )' requirements.txt \
       | grep -vE '^[[:space:]]*(#|$)' > /tmp/train_req.txt \
    && pip install -c /opt/constraints.txt -r /tmp/train_req.txt

# ---- Fail the BUILD, not a pod at 2am ----
# gcc must exist at RUNTIME: triton compiles a CUDA driver shim on first use.
# The 'runtime' base ships no compiler -> "Failed to find C compiler" killed the
# engine on first boot (2026-07-25). Verified here so it can never regress.
RUN which gcc && gcc --version | head -1

# The trainer must import BEFORE a pod ever tries to use it. A missing
# accelerate/transformers here would otherwise surface hours into stage 4.
RUN cd /opt/sd-scripts && python -c "\
import accelerate, transformers, safetensors; \
import library.train_util; \
import torch; \
assert torch.__version__.startswith('2.6.0'), 'trainer deps moved torch: '+torch.__version__; \
print('TRAIN_VERIFY_OK accelerate', accelerate.__version__, 'transformers', transformers.__version__)"

RUN cd $COMFY_HOME && python -c "\
import torch, insightface, onnxruntime, comfy.ldm.models; \
assert torch.__version__.startswith('2.6.0'), 'torch drifted: '+torch.__version__; \
assert torch.version.cuda == '12.4', 'cuda drifted: '+str(torch.version.cuda); \
print('BUILD_VERIFY_OK torch', torch.__version__, 'cu', torch.version.cuda, \
      'insightface', insightface.__version__)"

COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh

WORKDIR $COMFY_HOME
EXPOSE 22 3000
ENTRYPOINT ["/opt/entrypoint.sh"]
