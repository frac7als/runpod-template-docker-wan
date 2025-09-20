FROM runpod/pytorch:2.3.0-py3.10-cuda12.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/workspace/.cache/huggingface \
    HUGGINGFACE_HUB_CACHE=/workspace/.cache/huggingface \
    COMFYUI_PORT=8188

# ---- OS + Python deps ----
RUN apt-get update && apt-get install -y --no-install-recommends \
      git git-lfs aria2 curl ca-certificates ffmpeg tmux && \
    git lfs install && \
    python3 -m pip install --upgrade --no-cache-dir pip wheel setuptools && \
    python3 -m pip install --no-cache-dir huggingface_hub fastapi uvicorn && \
    rm -rf /var/lib/apt/lists/*

# ---- ComfyUI ----
RUN git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI && \
    git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager /opt/ComfyUI/custom_nodes/ComfyUI-Manager

# ---- Bootstrap script ----
COPY bootstrap.sh /usr/local/bin/bootstrap.sh
RUN chmod +x /usr/local/bin/bootstrap.sh

WORKDIR /opt/ComfyUI
EXPOSE 8188
CMD ["/usr/local/bin/bootstrap.sh"]
