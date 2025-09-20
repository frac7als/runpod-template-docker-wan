#!/usr/bin/env bash
set -euo pipefail

PORT="${COMFYUI_PORT:-8188}"
BASE="/workspace"                 # RunPod persistent volume
APP_DIR="/opt/ComfyUI"
MODELS="$BASE/models"

echo "[init] ComfyUI bootstrap starting… (no GGUF)"

# ------------------------------------------------------------
# Ensure ComfyUI exists (defensive; Dockerfile should clone it)
# ------------------------------------------------------------
if [ ! -d "$APP_DIR" ]; then
  echo "[warn] /opt/ComfyUI not found; cloning now"
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$APP_DIR"
fi

# ------------------------------------------------------------
# Persistent model tree + link into ComfyUI
# ------------------------------------------------------------
mkdir -p "$MODELS"/{checkpoints,loras,vae,clip,text_encoders,clip_vision,upscale_models,controlnet}
ln -sfn "$MODELS/checkpoints"     "$APP_DIR/models/checkpoints"
ln -sfn "$MODELS/loras"           "$APP_DIR/models/loras"
ln -sfn "$MODELS/vae"             "$APP_DIR/models/vae"
ln -sfn "$MODELS/clip"            "$APP_DIR/models/clip"
ln -sfn "$MODELS/text_encoders"   "$APP_DIR/models/text_encoders"
ln -sfn "$MODELS/clip_vision"     "$APP_DIR/models/clip_vision"
ln -sfn "$MODELS/upscale_models"  "$APP_DIR/models/upscale_models"
ln -sfn "$MODELS/controlnet"      "$APP_DIR/models/controlnet"

# ------------------------------------------------------------
# Custom nodes required by the workflow
# ------------------------------------------------------------
mkdir -p "$APP_DIR/custom_nodes"
cd "$APP_DIR/custom_nodes"

if [ ! -d ComfyUI-Manager ]; then
  git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager
fi
if [ ! -d ComfyUI-VideoHelperSuite ]; then
  git clone --depth=1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite
fi

# (Add other node packs here if your workflow needs them)
# Example:
# if [ ! -d ComfyUI-Impact-Pack ]; then
#   git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Impact-Pack
# fi

# ------------------------------------------------------------
# Install python requirements (ComfyUI + each custom node)
# ------------------------------------------------------------
cd "$APP_DIR"
python3 -m pip install --no-cache-dir -r requirements.txt || true
# Install any requirements.txt inside custom_nodes
while IFS= read -r req; do
  echo "[pip] installing deps for $req"
  python3 -m pip install --no-cache-dir -r "$req" || true
done < <(find custom_nodes -maxdepth 2 -name "requirements.txt" -type f)

# ------------------------------------------------------------
# Download helpers
# ------------------------------------------------------------
dl_url() { # dl_url <URL> <DEST_PATH>
  local url="$1"; local out="$2"
  if [ ! -f "$out" ]; then
    echo "[dl_url] $url -> $out"
    mkdir -p "$(dirname "$out")"
    aria2c -q -x16 -s16 -k1M --file-allocation=none \
      -o "$(basename "$out")" -d "$(dirname "$out")" "$url"
  else
    echo "[skip] $out exists"
  fi
}

dl_hf() { # dl_hf <REPO_ID> <FILENAME> <DEST_PATH> [REV]
  local repo="$1"; local file="$2"; local out="$3"; local rev="${4:-main}"
  if [ -f "$out" ]; then
    echo "[skip] $out exists"
    return 0
  fi
  echo "[dl_hf] $repo :: $file (rev=$rev) -> $out"
  python3 - "$repo" "$file" "$out" "$rev" << 'PY'
import os, sys
from pathlib import Path
from huggingface_hub import hf_hub_download

repo, fname, out, rev = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
Path(os.path.dirname(out)).mkdir(parents=True, exist_ok=True)
p = hf_hub_download(
    repo_id=repo, filename=fname, revision=rev,
    local_dir=os.path.dirname(out), local_dir_use_symlinks=False,
    token=os.environ.get("HF_TOKEN")
)
# rename/move to exact target filename if needed
if os.path.abspath(p) != os.path.abspath(out):
    if os.path.exists(out):
        os.remove(out)
    os.replace(p, out)
print("ok:", out)
PY
}

# ------------------------------------------------------------
# Required assets (WAN AIO; GGUF removed)
# ------------------------------------------------------------
# WAN 2.2 AIO UNET (image-to-video rapid)
dl_hf "Phr00t/WAN2.2-14B-Rapid-AllInOne" "wan2.2-i2v-rapid-aio.safetensors" \
      "$MODELS/checkpoints/wan2.2-i2v-rapid-aio.safetensors"

# WAN VAE & WAN text encoder used by CLIPLoader(type=wan)
dl_hf "Phr00t/WAN2.2-14B-Rapid-AllInOne" "wan_2.1_vae.safetensors" \
      "$MODELS/vae/wan_2.1_vae.safetensors"
dl_hf "Phr00t/WAN2.2-14B-Rapid-AllInOne" "umt5_xxl_fp8_e4m3fn_scaled.safetensors" \
      "$MODELS/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"

# ESRGAN upscale model referenced by video upscaler node (skip if not in repo)
dl_hf "Phr00t/WAN2.2-14B-Rapid-AllInOne" "4x_foolhardy_Remacri.pth" \
      "$MODELS/upscale_models/4x_foolhardy_Remacri.pth" || true

# ------------------------------------------------------------
# Optional: user-provided list without rebuilding
#   /workspace/models.user.txt lines support two formats:
#     hf  repo_id|filename|subdir/filename[|revision]
#     url https://...|subdir/filename
# ------------------------------------------------------------
USER_LIST="$BASE/models.user.txt"
if [ -f "$USER_LIST" ]; then
  echo "[info] Found $USER_LIST — processing extra downloads"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    kind="${line%% *}"; rest="${line#* }"
    if [ "$kind" = "hf" ]; then
      IFS='|' read -r repo fname rel rev <<< "$rest"
      [ -z "${rev:-}" ] && rev="main"
      dl_hf "$repo" "$fname" "$MODELS/$rel" "$rev" || true
    elif [ "$kind" = "url" ]; then
      IFS='|' read -r url rel <<< "$rest"
      dl_url "$url" "$MODELS/$rel" || true
    fi
  done < "$USER_LIST"
fi

# ------------------------------------------------------------
# Launch ComfyUI
# ------------------------------------------------------------
cd "$APP_DIR"
echo "[run] ComfyUI listening on 0.0.0.0:$PORT"
exec python3 main.py --listen 0.0.0.0 --port "$PORT"
