#!/usr/bin/env bash
set -euo pipefail

PORT="${COMFYUI_PORT:-8188}"
BASE="/workspace"                 # RunPod persistent volume
APP_DIR="/opt/ComfyUI"
MODELS="$BASE/models"

# ---- Prepare persistent model tree + link into ComfyUI ----
mkdir -p "$MODELS"/{checkpoints,loras,vae,clip,text_encoders,clip_vision,upscale_models,controlnet}
ln -sfn "$MODELS/checkpoints"     "$APP_DIR/models/checkpoints"
ln -sfn "$MODELS/loras"           "$APP_DIR/models/loras"
ln -sfn "$MODELS/vae"             "$APP_DIR/models/vae"
ln -sfn "$MODELS/clip"            "$APP_DIR/models/clip"
ln -sfn "$MODELS/text_encoders"   "$APP_DIR/models/text_encoders"
ln -sfn "$MODELS/clip_vision"     "$APP_DIR/models/clip_vision"
ln -sfn "$MODELS/upscale_models"  "$APP_DIR/models/upscale_models"
ln -sfn "$MODELS/controlnet"      "$APP_DIR/models/controlnet"

# ---- Download helpers ----
dl_url() { # dl_url <URL> <DEST_PATH>
  local url="$1"; local out="$2"
  if [ ! -f "$out" ]; then
    echo "[dl_url] $url -> $out"
    mkdir -p "$(dirname "$out")"
    aria2c -q -x16 -s16 -k1M --file-allocation=none -o "$(basename "$out")" -d "$(dirname "$out")" "$url"
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
p = hf_hub_download(repo_id=repo, filename=fname, revision=rev, local_dir=os.path.dirname(out), local_dir_use_symlinks=False)
# ensure final name exactly matches 'out'
if os.path.abspath(p) != os.path.abspath(out):
    if os.path.exists(out): os.remove(out)
    os.replace(p, out)
print("ok:", out)
PY
}

# ---- Your default model set (edit/extend) ----
# Hugging Face items (repo | filename | target path relative to $MODELS)
dl_hf "comfyanonymous/flux_text_encoders" "clip_l.safetensors"     "$MODELS/text_encoders/clip_l.safetensors"
dl_hf "comfyanonymous/flux_text_encoders" "t5xxl_fp16.safetensors" "$MODELS/text_encoders/t5xxl_fp16.safetensors"
dl_hf "stabilityai/sdxl-vae"              "sdxl_vae.safetensors"   "$MODELS/vae/sdxl_vae.safetensors"

# Example LORAs / checkpoints by direct URL (uncomment + replace with real links)
# dl_url "https://YOUR_HOST/flux_base.safetensors"      "$MODELS/checkpoints/flux_base.safetensors"
# dl_url "https://YOUR_HOST/time_tale_lora.safetensors" "$MODELS/loras/time_tale_lora.safetensors"
# dl_url "https://YOUR_HOST/ultrareal_v2.safetensors"   "$MODELS/loras/ultrareal_v2.safetensors"

# Optional: load user-specified downloads from a file in the volume (no rebuild needed)
# Lines format:
#   hf repo_id|filename|subdir/filename[|revision]
#   url https://...|subdir/filename
USER_LIST="$BASE/models.user.txt"
if [ -f "$USER_LIST" ]; then
  echo "[info] Found $USER_LIST — processing extra downloads"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    kind="${line%% *}"; rest="${line#* }"
    if [ "$kind" = "hf" ]; then
      IFS='|' read -r repo fname rel rev <<< "$rest"
      [ -z "${rev:-}" ] && rev="main"
      dl_hf "$repo" "$fname" "$MODELS/$rel" "$rev"
    elif [ "$kind" = "url" ]; then
      IFS='|' read -r url rel <<< "$rest"
      dl_url "$url" "$MODELS/$rel"
    fi
  done < "$USER_LIST"
fi

# ---- Launch ComfyUI ----
cd "$APP_DIR"
echo "[run] ComfyUI on 0.0.0.0:$PORT"
exec python3 main.py --listen 0.0.0.0 --port "$PORT"
