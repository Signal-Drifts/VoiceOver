#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
seed_root="$project_root/third_party/seed-vc"
commit="51383efd921027683c89e5348211d93ff12ac2a8"

command -v uv >/dev/null || { echo "Install uv first: https://docs.astral.sh/uv/" >&2; exit 1; }
[[ ! -e "$seed_root" ]] || { echo "$seed_root already exists." >&2; exit 1; }
mkdir -p "$(dirname "$seed_root")"
git clone https://github.com/Plachtaa/seed-vc.git "$seed_root"
git -C "$seed_root" checkout "$commit"
uv venv --python 3.10 "$seed_root/.venv"
uv pip install --python "$seed_root/.venv/bin/python" --prerelease allow torch torchvision torchaudio torchcodec
uv pip install --python "$seed_root/.venv/bin/python" -r "$project_root/scripts/seed-vc-requirements.txt"
git -C "$seed_root" apply "$project_root/scripts/seed-vc-output.patch"
echo "Seed-VC is ready at $seed_root"
