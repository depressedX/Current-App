#!/bin/zsh
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
# Only the PC needs Python and the paired ~501 MB text encoder.
uv venv --python 3.11 "$HERE/.venv" --allow-existing
uv pip install --python "$HERE/.venv/bin/python" -r "$HERE/requirements.lock"
exec "$HERE/.venv/bin/python" "$HERE/generate.py" "$@"
