#!/usr/bin/env bash
# The model test on a rented GPU: an Ubuntu box with an NVIDIA card of 24 GB (an RTX 4090 or an L4
# pod on RunPod, for example) that you reach by ssh. The services are called from there too, so
# your clips and keys never go through a Russian connection to OpenAI or ElevenLabs.
#
# On the Mac:
#   scripts/model_test/gpu_box.sh send <user@host> [-p <ssh port>] [-i <ssh key>] [--keys <env file>] [--dir <work folder>] [--dry-run]
#       copies the runner, your clips that are in the test (never the private ones, never the others)
#       and the keys file to ~/murmur-model-test on the box. --dry-run builds the bundle, checks it and
#       shows what would go, without connecting.
#   scripts/model_test/gpu_box.sh fetch <user@host> [-p <ssh port>] [-i <ssh key>] [--dir <work folder>]
#       brings the results and the report back into the work folder; then vote on the vote page.
#
# On the box, in ~/murmur-model-test/repo:
#   bash scripts/model_test/gpu_box.sh setup    ffmpeg, Deno, uv, vLLM and onnx-asr for the GPU, and the models (~15 min, ~40 GB)
#   bash scripts/model_test/gpu_box.sh run      every candidate: your own models one at a time, each with the whole GPU,
#                                               then the services; writes the report
#
# The keys file holds OPENAI_API_KEY, SONIOX_API_KEY and ELEVENLABS_API_KEY as NAME=value lines. Keep
# it outside the repository; it goes to the box with mode 600 and nowhere else. A pod bills by the
# hour while it runs: stop or terminate it once `fetch` has the results.
set -euo pipefail

REMOTE_ROOT='~/murmur-model-test'
DENO_VERSION=2.9.7

say() { printf '%s\n' "$*"; }
die() {
  printf 'Stopped: %s\n' "$*" >&2
  exit 1
}

# MARK: On the Mac

repo_root() { cd "$(dirname "$0")/../.." && pwd; }

# The local modules run.ts imports, as the repository's relative paths (deno info knows them all).
runner_files() {
  local root=$1
  (cd "$root" && deno info --json scripts/model_test/run.ts) | python3 -I -c '
import json, os, sys
root = sys.argv[1]
for module in json.load(sys.stdin)["modules"]:
    specifier = module.get("specifier", "")
    if specifier.startswith("file://"):
        print(os.path.relpath(specifier[7:], root))
' "$root"
}

ssh_options() { # the ssh options from -p and -i, one per line
  [ -z "$PORT" ] || printf '%s\n' -p "$PORT"
  [ -z "$KEY" ] || printf '%s\n' -i "$KEY"
  printf '%s\n' -o ServerAliveInterval=30
}

cmd_send() {
  local root stage clips mb keys_names options=()
  root=$(repo_root)
  command -v deno >/dev/null || die "deno is needed on this Mac to find the runner's files"
  [ -f "$DIR/clips.json" ] || die "no $DIR/clips.json: pull your recordings and correct them first"
  stage=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/model-test-send.XXXXXX")
  # Expanded now: the bundle (clips, keys) is removed when the script ends, however it ends.
  # shellcheck disable=SC2064
  trap "rm -rf '$stage'" EXIT
  mkdir -p "$stage/repo" "$stage/work/audio"

  # The runner and what it imports, the model server, this script, the candidates of the plan.
  for file in $(runner_files "$root") scripts/model_test/model_server.py scripts/model_test/gpu_box.sh scripts/model_test/candidates.example.json; do
    mkdir -p "$stage/repo/$(dirname "$file")"
    cp "$root/$file" "$stage/repo/$file"
  done

  # Only the clips in the test, and only theirs: the manifest is cut down to them.
  clips=$(python3 -I - "$DIR" "$stage/work" <<'PY'
import json, shutil, sys
source, target = sys.argv[1], sys.argv[2]
manifest = json.load(open(f"{source}/clips.json"))
keep = [clip for clip in manifest["clips"] if clip.get("selected") and not clip.get("excluded")]
for clip in keep:
    shutil.copyfile(f"{source}/{clip['file']}", f"{target}/{clip['file']}")
manifest["clips"] = keep
json.dump(manifest, open(f"{target}/clips.json", "w"), ensure_ascii=False, indent=2)
print(len(keep))
PY
)
  [ "$clips" -gt 0 ] || die "no clip is in the test: choose them on the correction page first"
  if [ -f "$DIR/candidates.json" ]; then
    cp "$DIR/candidates.json" "$stage/work/candidates.json"
  else
    cp "$root/scripts/model_test/candidates.example.json" "$stage/work/candidates.json"
  fi
  keys_names="none"
  if [ -n "$KEYS" ]; then
    [ -f "$KEYS" ] || die "no keys file $KEYS"
    case "$(cd "$(dirname "$KEYS")" && pwd -P)/" in
      "$root/scripts/out/"*) ;;
      "$root/"*) die "$KEYS is inside the repository, where a commit could pick it up: keep it outside" ;;
    esac
    (umask 077 && cp "$KEYS" "$stage/keys.env")
    keys_names=$(grep -E '^[A-Z_][A-Z0-9_]*=' "$KEYS" | cut -d= -f1 | tr '\n' ' ')
  fi

  # The bundle must run on its own: everything the runner imports is in it.
  (cd "$stage/repo" && deno check scripts/model_test/run.ts >/dev/null 2>&1) || die "the bundle doesn't type-check on its own: a file is missing"
  mb=$(du -sk "$stage/work/audio" | awk '{ printf "%.1f", $1 / 1024 }')
  say "To send to $TARGET:$REMOTE_ROOT"
  say "  the runner: $(cd "$stage/repo" && find . -type f | wc -l | tr -d ' ') files (checked: it runs on its own)"
  say "  your clips: $clips in the test ($mb MB of audio) and their corrected texts; private and unchosen clips stay here"
  say "  candidates: $(python3 -I -c 'import json,sys; print(", ".join(c["name"] for c in json.load(open(sys.argv[1]))["candidates"]))' "$stage/work/candidates.json")"
  say "  keys: $keys_names"
  say ""
  say "The clips go to a machine you rent, and from there to the services in the candidates file (OpenAI, Soniox,"
  say "ElevenLabs): only send them if you agree to that."
  while IFS= read -r option; do options+=("$option"); done < <(ssh_options)
  if [ "$DRY_RUN" = 1 ]; then
    say ""
    say "[dry run] would run: tar -C <bundle> -czf - . | ssh ${options[*]} $TARGET 'mkdir -p $REMOTE_ROOT && tar -xzf - -C $REMOTE_ROOT'"
    [ -z "${MODEL_TEST_KEEP_BUNDLE:-}" ] || { cp -R "$stage/." "$MODEL_TEST_KEEP_BUNDLE/"; say "A copy of the bundle: $MODEL_TEST_KEEP_BUNDLE"; }
    return 0
  fi
  printf 'Send it? Type yes to go on: ' >/dev/tty
  read -r answer </dev/tty || true
  [ "$answer" = yes ] || die "nothing was sent."
  tar -C "$stage" -czf - . | ssh "${options[@]}" "$TARGET" \
    "mkdir -p $REMOTE_ROOT && tar -xzf - -C $REMOTE_ROOT && { [ ! -f $REMOTE_ROOT/keys.env ] || chmod 600 $REMOTE_ROOT/keys.env; } && echo received"
  say ""
  say "Next, on the box: cd $REMOTE_ROOT/repo && bash scripts/model_test/gpu_box.sh setup && bash scripts/model_test/gpu_box.sh run"
  say "Then here: scripts/model_test/gpu_box.sh fetch $TARGET${PORT:+ -p $PORT}${KEY:+ -i $KEY}"
}

cmd_fetch() {
  local options=() stamp
  while IFS= read -r option; do options+=("$option"); done < <(ssh_options)
  mkdir -p "$DIR"
  if [ -d "$DIR/results" ]; then
    stamp=$(date +%Y%m%d-%H%M%S)
    mv "$DIR/results" "$DIR/results.before-$stamp"
    say "The results that were here are kept in $DIR/results.before-$stamp."
  fi
  ssh "${options[@]}" "$TARGET" "cd $REMOTE_ROOT/work && tar -czf - results report.md report.json" | tar -xzf - -C "$DIR"
  say "Fetched into $DIR: results/, report.md, report.json."
  say "Vote: deno run --allow-net=127.0.0.1 --allow-read --allow-write scripts/model_test/review.ts --dir $DIR  (then /vote)"
  say "Remember to stop or terminate the GPU pod: it bills by the hour."
}

# MARK: On the box

as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

cmd_setup() {
  command -v nvidia-smi >/dev/null || die "no nvidia-smi: this isn't a box with an NVIDIA GPU and its driver"
  say "GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -n 1)"
  as_root apt-get update -q
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q ffmpeg unzip curl ca-certificates
  if ! command -v uv >/dev/null && [ ! -x "$HOME/.local/bin/uv" ]; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  export PATH="$HOME/.local/bin:$HOME/.deno/bin:$PATH"
  if [ ! -x "$HOME/.deno/bin/deno" ]; then
    mkdir -p "$HOME/.deno/bin"
    curl -fsSL -o /tmp/deno.zip "https://github.com/denoland/deno/releases/download/v$DENO_VERSION/deno-x86_64-unknown-linux-gnu.zip"
    unzip -o -q /tmp/deno.zip -d "$HOME/.deno/bin" && rm -f /tmp/deno.zip
  fi
  say "Deno $("$HOME/.deno/bin/deno" --version | head -n 1)"

  # vLLM serves Qwen3-ASR, Whisper turbo and Voxtral Realtime (0.20 or newer for Voxtral).
  [ -d "$HOME/.venvs/vllm" ] || uv venv "$HOME/.venvs/vllm" --python 3.12
  VIRTUAL_ENV="$HOME/.venvs/vllm" uv pip install -U "vllm[audio]>=0.20" "mistral-common[audio]>=1.9.0" transformers --torch-backend=auto
  # onnx-asr serves Parakeet and GigaAM through model_server.py.
  [ -d "$HOME/.venvs/onnx" ] || uv venv "$HOME/.venvs/onnx" --python 3.12
  VIRTUAL_ENV="$HOME/.venvs/onnx" uv pip install -U "onnx-asr[hub]" "onnxruntime-gpu[cuda,cudnn]" numpy

  say "Downloading the models (once; later starts load them from disk)…"
  "$HOME/.venvs/vllm/bin/python" - <<'PY'
from huggingface_hub import snapshot_download
for repo in ("Qwen/Qwen3-ASR-1.7B", "openai/whisper-large-v3-turbo", "mistralai/Voxtral-Mini-4B-Realtime-2602"):
    print("  ", repo, flush=True)
    snapshot_download(repo)
PY
  "$HOME/.venvs/onnx/bin/python" - <<'PY'
import onnx_asr
for name in ("nemo-parakeet-tdt-0.6b-v3", "gigaam-multilingual-large-ctc"):
    print("  ", name, flush=True)
    onnx_asr.load_model(name, providers=["CPUExecutionProvider"])
# Splits a clip over 28 s at its pauses (model_server.py --vad-over).
onnx_asr.load_vad("silero", providers=["CPUExecutionProvider"])
PY
  say ""
  say "Ready. Next: bash scripts/model_test/gpu_box.sh run"
}

cmd_run() {
  local deno="$HOME/.deno/bin/deno" env_file=() work
  [ -x "$deno" ] || die "Deno isn't installed here: run gpu_box.sh setup first"
  work=$(cd .. && pwd)/work
  [ -f "$work/clips.json" ] || die "no $work/clips.json: send the clips from the Mac first"
  if [ -f ../keys.env ]; then env_file=(--env-file=../keys.env); else say "No keys.env: the services are skipped, the open models run."; fi
  say "GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -n 1)"
  "$deno" run --allow-net --allow-read --allow-write --allow-env --allow-run "${env_file[@]}" \
    scripts/model_test/run.ts --dir "$work" --serve "$@"
  say ""
  say "Done. On the Mac: scripts/model_test/gpu_box.sh fetch <this box>. Then stop or terminate this pod."
}

# MARK: Arguments

COMMAND=${1:-}
[ $# -gt 0 ] && shift || true
TARGET=""
PORT=""
KEY=""
KEYS=""
DIR=scripts/out/model_test
DRY_RUN=0
EXTRA=()
case $COMMAND in
  send | fetch)
    TARGET=${1:-}
    [ -n "$TARGET" ] && [ "${TARGET#-}" = "$TARGET" ] || die "$COMMAND needs the box: user@host (RunPod shows it under Connect › SSH)"
    shift
    ;;
esac
while [ $# -gt 0 ]; do
  case $1 in
    -p) PORT=${2:?}; shift ;;
    -i) KEY=${2:?}; shift ;;
    --keys) KEYS=${2:?}; shift ;;
    --dir) DIR=${2:?}; shift ;;
    --dry-run) DRY_RUN=1 ;;
    *) EXTRA+=("$1") ;;
  esac
  shift
done

case $COMMAND in
  send) cmd_send ;;
  fetch) cmd_fetch ;;
  setup) cmd_setup ;;
  run) cmd_run ${EXTRA[@]+"${EXTRA[@]}"} ;;
  *) sed -n '2,24p' "$0"; exit 2 ;;
esac
