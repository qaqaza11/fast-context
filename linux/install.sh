#!/usr/bin/env bash
# install.sh — Linux x86_64 installer for fast-context-linux.
#
# Installs the user-local runtime at $FC_HOME (default ~/.local/share/fast-context):
#   - isolated Python 3.12 venv with document/OCR/audio dependency groups
#   - system tools: ripgrep, fd, ffmpeg/ffprobe (apt), ast-grep (npm or pip), best-effort
#   - ~/.local/bin/fc-* launchers, skill files at ~/.agents/skills/fast-context-linux
#
# Usage: bash install.sh [--check-only] [--update] [--skip-ocr] [--skip-audio]
#                        [--skip-dependencies] [--no-path] [--no-verify] [--home DIR]
set -euo pipefail

VERSION='0.1.0'
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FC_HOME="${HOME}/.local/share/fast-context"
SKILL_DIR="${HOME}/.agents/skills/fast-context-linux"
CHECK_ONLY=0 UPDATE=0 SKIP_OCR=0 SKIP_AUDIO=0 SKIP_DEPS=0 NO_PATH=0 NO_VERIFY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --check-only) CHECK_ONLY=1 ;;
        --update) UPDATE=1 ;;
        --skip-ocr) SKIP_OCR=1 ;;
        --skip-audio) SKIP_AUDIO=1 ;;
        --skip-dependencies) SKIP_DEPS=1 ;;
        --no-path) NO_PATH=1 ;;
        --no-verify) NO_VERIFY=1 ;;
        --home) FC_HOME="$2"; shift ;;
        --home=*) FC_HOME="${1#--home=}" ;;
        -h|--help) sed -n '1,12p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

BIN_DIR="${HOME}/.local/bin"
VENV_PY="${FC_HOME}/.venv/bin/python"
LOGS_DIR="${FC_HOME}/logs"
RESULTS_FILE=""
TOOLS_FILE=""

log() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; }

record() { # item status detail
    python3 -c 'import json,sys; print(json.dumps({"item":sys.argv[1],"status":sys.argv[2],"detail":sys.argv[3]},ensure_ascii=False))' \
        "$1" "$2" "$3" >> "$RESULTS_FILE"
}

record_tool() { # name path
    python3 -c 'import json,sys; print(json.dumps([sys.argv[1],sys.argv[2]],ensure_ascii=False))' \
        "$1" "$2" >> "$TOOLS_FILE"
}

command_works() { # name [probe-args...]
    local bin="$1"; shift
    [ -n "$bin" ] && [ -x "$bin" ] && "$bin" "$@" >/dev/null 2>&1
}

# ---------------------------------------------------------------- platform
if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
    err "This installer supports Linux x86_64 only (got $(uname -s) $(uname -m))."
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    err "python3 is required. Install it, e.g.: sudo apt-get install -y python3.12 python3.12-venv"
    exit 1
fi
if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 12) else 1)'; then
    err "Python 3.12 is required (found $(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))'))."
    err "Install it, e.g.: sudo apt-get install -y python3.12 python3.12-venv"
    exit 1
fi

# ---------------------------------------------------------------- check-only
if [ "$CHECK_ONLY" = 1 ]; then
    python3 - "$FC_HOME" "$SKILL_DIR" "$SKIP_OCR" "$SKIP_AUDIO" "$NO_PATH" <<'EOF'
import json, shutil, subprocess, sys
home, skill, skip_ocr, skip_audio, no_path = sys.argv[1], sys.argv[2], sys.argv[3] == '1', sys.argv[4] == '1', sys.argv[5] == '1'
def inv(name):
    path = shutil.which(name)
    working = False
    if path:
        try:
            probe = ['-version'] if name in ('ffmpeg', 'ffprobe') else ['--version']
            working = subprocess.run([path] + probe, capture_output=True, timeout=15).returncode == 0
        except Exception:
            working = False
    return {'tool': name, 'present': bool(path), 'working': working, 'path': path}
tools = [inv(n) for n in ('apt-get', 'curl', 'python3', 'rg', 'fd', 'fdfind', 'ffmpeg', 'ffprobe', 'npm', 'ast-grep', 'sg', 'markitdown')]
print(json.dumps({'mode': 'check-only', 'skill_directory': skill, 'runtime': home,
                  'tools': tools, 'python': '3.12', 'ocr': not skip_ocr, 'audio': not skip_audio,
                  'user_path': not no_path,
                  'models': 'downloaded only when OCR/transcription is first used'}, indent=2, ensure_ascii=False))
EOF
    exit 0
fi

# ---------------------------------------------------------------- prepare dirs
mkdir -p "$FC_HOME" "$LOGS_DIR" "${FC_HOME}/backups" "$BIN_DIR"
RESULTS_FILE="$(mktemp)"
TOOLS_FILE="$(mktemp)"
INSTALL_LOG="${FC_HOME}/install.log"
exec > >(tee -a "$INSTALL_LOG") 2>&1
log "fast-context-linux installer v${VERSION} — $(date -u +%FT%TZ)"

try_step() { # label -- command...
    local label="$1"; shift
    local logfile="${LOGS_DIR}/${label}.log"
    if "$@" >"$logfile" 2>&1; then
        return 0
    else
        log "step '${label}' failed; see ${logfile}"
        return 1
    fi
}

# ---------------------------------------------------------------- system tools
# Only touch apt when something is actually missing; a hanging mirror must
# never block the whole install (best-effort with a timeout).
APT_OK=0
NEED_APT=0
for _t in rg fdfind ffmpeg curl; do
    command -v "$_t" >/dev/null 2>&1 || NEED_APT=1
done
python3 -c 'import venv, ensurepip' 2>/dev/null || NEED_APT=1
if [ "$NEED_APT" = 1 ] && command -v apt-get >/dev/null 2>&1; then
    if try_step apt-update timeout 120 apt-get update -qq; then APT_OK=1; fi
fi

ensure_tool() { # name apt-package probe-args...
    local name="$1" package="$2"; shift 2
    local bin
    bin="$(command -v "$name" || true)"
    local status='reused'
    if ! command_works "$bin" "$@"; then
        if [ "$APT_OK" = 1 ]; then
            if try_step "apt-${name}" apt-get install -y "$package"; then
                bin="$(command -v "$name" || true)"
                status='installed'
            fi
        fi
        if ! command_works "$bin" "$@"; then
            record "$name" 'failed' "could not install or run ${name}"
            return 0
        fi
    fi
    record_tool "$name" "$bin"
    record "$name" "$status" "$bin"
}

ensure_tool rg ripgrep --version
ensure_tool ffmpeg ffmpeg -version
ensure_tool ffprobe ffmpeg -version
ensure_tool curl curl --version

# Debian/Ubuntu ship fd as fdfind; provide a stable `fd` symlink.
FD_BIN="$(command -v fd || true)"
if ! command_works "$FD_BIN" --version; then
    FDFIND_BIN="$(command -v fdfind || true)"
    if ! command_works "$FDFIND_BIN" --version && [ "$APT_OK" = 1 ]; then
        try_step apt-fd apt-get install -y fd-find || true
        FDFIND_BIN="$(command -v fdfind || true)"
    fi
    if command_works "$FDFIND_BIN" --version; then
        ln -sf "$FDFIND_BIN" "${BIN_DIR}/fd"
        FD_BIN="${BIN_DIR}/fd"
        record_tool fd "$FD_BIN"
        record fd 'installed' "$FD_BIN (symlink to ${FDFIND_BIN})"
    else
        record fd 'failed' 'fd/fdfind could not be installed'
    fi
else
    record_tool fd "$FD_BIN"
    record fd 'reused' "$FD_BIN"
fi

# ---------------------------------------------------------------- python venv
if [ ! -x "$VENV_PY" ]; then
    if [ "$SKIP_DEPS" = 1 ]; then
        err "--skip-dependencies requires a prepared runtime with ${VENV_PY}"
        exit 1
    fi
    if ! python3 -c 'import venv' 2>/dev/null || ! python3 -c 'import ensurepip' 2>/dev/null; then
        if [ "$APT_OK" = 1 ]; then
            try_step apt-venv apt-get install -y python3.12-venv || try_step apt-venv2 apt-get install -y python3-venv || true
        fi
    fi
    if ! try_step venv python3 -m venv "${FC_HOME}/.venv"; then
        err "Could not create the Python 3.12 venv; see ${LOGS_DIR}/venv.log"
        exit 1
    fi
fi
PY_VERSION="$("$VENV_PY" -c "import sys; print('%d.%d' % sys.version_info[:2])")"
if [ "$PY_VERSION" != "3.12" ]; then
    err "An incompatible runtime already exists at ${FC_HOME} (python ${PY_VERSION}); choose another --home."
    exit 1
fi
try_step pip-upgrade "$VENV_PY" -m pip install --upgrade pip || log "pip upgrade failed; continuing"

install_group() { # name requirements-file [extra pip args...]
    local name="$1" req="$2"; shift 2
    if try_step "pip-${name}" "$VENV_PY" -m pip install -r "$req" "$@"; then
        record "$name" 'ready' 'isolated Python dependencies resolved'
    else
        record "$name" 'failed' "see ${LOGS_DIR}/pip-${name}.log"
    fi
}

if [ "$SKIP_DEPS" = 0 ]; then
    install_group documents "${SOURCE_DIR}/requirements-core.txt"
    if [ "$SKIP_AUDIO" = 0 ]; then
        install_group audio "${SOURCE_DIR}/requirements-audio.txt"
    fi
    if [ "$SKIP_OCR" = 0 ]; then
        if try_step pip-paddle-cpu "$VENV_PY" -m pip install 'paddlepaddle==3.3.0' \
                --index-url 'https://www.paddlepaddle.org.cn/packages/stable/cpu/'; then
            install_group ocr "${SOURCE_DIR}/requirements-ocr.txt"
        else
            record ocr 'failed' "paddlepaddle CPU install failed; see ${LOGS_DIR}/pip-paddle-cpu.log"
        fi
    fi
fi

# ---------------------------------------------------------------- ast-grep
AST_BIN="$(command -v ast-grep || true)"
[ -z "$AST_BIN" ] && AST_BIN="$(command -v sg || true)"
AST_STATUS='reused'
if ! command_works "$AST_BIN" --version; then
    if [ "$SKIP_DEPS" = 0 ] && command -v npm >/dev/null 2>&1; then
        if try_step ast-grep-npm npm install -g @ast-grep/cli; then
            AST_BIN="$(command -v ast-grep || true)"
            [ -z "$AST_BIN" ] && AST_BIN="$(command -v sg || true)"
            AST_STATUS='installed'
        fi
    fi
    if ! command_works "$AST_BIN" --version && [ "$SKIP_DEPS" = 0 ]; then
        if try_step ast-grep-pip "$VENV_PY" -m pip install ast-grep-cli; then
            AST_BIN="$([ -x "${FC_HOME}/.venv/bin/ast-grep" ] && echo "${FC_HOME}/.venv/bin/ast-grep" || echo "${FC_HOME}/.venv/bin/sg")"
            AST_STATUS='installed'
        fi
    fi
fi
if command_works "$AST_BIN" --version; then
    record_tool ast-grep "$AST_BIN"
    record ast-grep "$AST_STATUS" "$AST_BIN"
else
    record ast-grep 'failed' 'ast-grep/sg could not be installed'
fi

# ---------------------------------------------------------------- skill files
MANAGED=(SKILL.md README.md LICENSE install.sh requirements-core.txt requirements-ocr.txt requirements-audio.txt)
mapfile -t SCRIPT_FILES < <(cd "$SOURCE_DIR/scripts" && printf 'scripts/%s\n' *.py)
ALL_MANAGED=("${MANAGED[@]}" "${SCRIPT_FILES[@]}")

skill_differs() {
    local rel from to
    for rel in "${ALL_MANAGED[@]}"; do
        from="${SOURCE_DIR}/${rel}"
        to="${SKILL_DIR}/${rel}"
        if [ -f "$from" ] && [ -f "$to" ] && ! cmp -s "$from" "$to"; then
            return 0
        fi
    done
    return 1
}

if [ -f "${SKILL_DIR}/SKILL.md" ] && skill_differs && [ "$UPDATE" = 0 ]; then
    err "Existing fast-context-linux skill differs. Re-run with --update to back up and update it."
    exit 1
fi

BACKUP_DIR="${FC_HOME}/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "${SKILL_DIR}/scripts"
for rel in "${ALL_MANAGED[@]}"; do
    from="${SOURCE_DIR}/${rel}"
    to="${SKILL_DIR}/${rel}"
    [ -f "$from" ] || continue
    if [ -f "$to" ] && ! cmp -s "$from" "$to"; then
        mkdir -p "${BACKUP_DIR}/$(dirname "$rel")"
        cp -p "$to" "${BACKUP_DIR}/${rel}"
    fi
    mkdir -p "$(dirname "$to")"
    cp -p "$from" "$to"
done
if [ -d "$BACKUP_DIR" ] && [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
    rmdir "$BACKUP_DIR" 2>/dev/null || true
fi

# ---------------------------------------------------------------- state
cp -p "${SKILL_DIR}/scripts/entrypoint.py" "${FC_HOME}/entrypoint.py"

TOOLS_JSON="$(python3 -c 'import json,sys; print(json.dumps(dict(json.loads(l) for l in sys.stdin if l.strip())))' < "$TOOLS_FILE")"
RESULTS_JSON="$(python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()]))' < "$RESULTS_FILE")"
export FC_HOME SKILL_DIR VERSION TOOLS_JSON RESULTS_JSON SKIP_OCR SKIP_AUDIO
python3 - <<'EOF'
import json, os
state = {
    'version': os.environ['VERSION'],
    'skill_directory': os.environ['SKILL_DIR'],
    'runtime': os.environ['FC_HOME'],
    'tools': json.loads(os.environ['TOOLS_JSON']),
    'results': json.loads(os.environ['RESULTS_JSON']),
    'optional_groups': {'ocr': os.environ['SKIP_OCR'] == '0', 'audio': os.environ['SKIP_AUDIO'] == '0'},
}
path = os.path.join(os.environ['FC_HOME'], 'installation.json')
with open(path, 'w', encoding='utf-8') as f:
    json.dump(state, f, ensure_ascii=False, indent=2)
print('wrote', path)
EOF

# ---------------------------------------------------------------- launchers
for helper in inspect-media extract-keyframes contact-sheet transcribe batch-ocr verify; do
    cat > "${BIN_DIR}/fc-${helper}" <<EOF
#!/usr/bin/env bash
export PYTHONIOENCODING=utf-8
FC_HOME="\${FAST_CONTEXT_HOME:-\$HOME/.local/share/fast-context}"
exec "\$FC_HOME/.venv/bin/python" "\$FC_HOME/entrypoint.py" ${helper} "\$@"
EOF
    chmod +x "${BIN_DIR}/fc-${helper}"
done
if [ -x "${FC_HOME}/.venv/bin/markitdown" ]; then
    ln -sf "${FC_HOME}/.venv/bin/markitdown" "${BIN_DIR}/markitdown"
fi

# ---------------------------------------------------------------- PATH
if [ "$NO_PATH" = 0 ]; then
    case ":${PATH}:" in
        *":${BIN_DIR}:"*) log "${BIN_DIR} already on PATH" ;;
        *)
            if ! grep -q 'fast-context-linux' "${HOME}/.bashrc" 2>/dev/null; then
                printf '\n# fast-context-linux\n[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"\n' >> "${HOME}/.bashrc"
                log "appended ${BIN_DIR} to PATH in ~/.bashrc (new terminals)"
            fi
            export PATH="${BIN_DIR}:${PATH}"
            record path 'notice' "${BIN_DIR} added for this shell; open a new terminal for other shells"
            ;;
    esac
fi

# ---------------------------------------------------------------- verify
export FAST_CONTEXT_HOME="$FC_HOME"
if [ "$NO_VERIFY" = 0 ]; then
    VERIFY_ARGS=()
    [ "$SKIP_OCR" = 1 ] && VERIFY_ARGS+=(--skip-ocr)
    [ "$SKIP_AUDIO" = 1 ] && VERIFY_ARGS+=(--skip-audio)
    if "$VENV_PY" "${SKILL_DIR}/scripts/verify.py" --output "${FC_HOME}/verification.json" "${VERIFY_ARGS[@]+"${VERIFY_ARGS[@]}"}"; then
        record verification 'passed' 'see verification.json'
    else
        record verification 'failed' 'see verification.json and logs; remaining tools may still work'
    fi
    # refresh installation.json with the final results
    RESULTS_JSON="$(python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()]))' < "$RESULTS_FILE")"
    export RESULTS_JSON
    python3 - <<'EOF'
import json, os
path = os.path.join(os.environ['FC_HOME'], 'installation.json')
with open(path, encoding='utf-8') as f:
    state = json.load(f)
state['results'] = json.loads(os.environ['RESULTS_JSON'])
with open(path, 'w', encoding='utf-8') as f:
    json.dump(state, f, ensure_ascii=False, indent=2)
EOF
fi

# ---------------------------------------------------------------- summary
log ''
log 'Installation summary:'
python3 -c 'import json,sys; [print("  %-14s %-9s %s" % (r["item"], r["status"], r["detail"])) for r in (json.loads(l) for l in sys.stdin if l.strip())]' < "$RESULTS_FILE"
log "Skill:   ${SKILL_DIR}"
log "Runtime: ${FC_HOME}"
log 'Open a new terminal so ~/.local/bin is on PATH.'

rm -f "$RESULTS_FILE" "$TOOLS_FILE"
if grep -q '"status": "failed"' "${FC_HOME}/installation.json"; then
    exit 1
fi
exit 0
