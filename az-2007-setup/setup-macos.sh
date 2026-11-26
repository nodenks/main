#!/usr/bin/env bash
# Installs and verifies everything needed for the AZ-2007 GitHub Copilot labs on macOS (Homebrew).
#
# Usage:
#   chmod +x setup-macos.sh
#   ./setup-macos.sh                  # install + verify
#   ./setup-macos.sh --check-only     # verify only
#   ./setup-macos.sh --skip-smoke-test
#
# Not covered on macOS: SQL Server LocalDB (Windows-only). See README.md for LAB_AK_14.
# Written for the bash 3.2 that ships with macOS.

set -uo pipefail

CHECK_ONLY=0
SMOKE=1
for arg in "$@"; do
  case "$arg" in
    --check-only) CHECK_ONLY=1 ;;
    --skip-smoke-test) SMOKE=0 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

LAB_REPO=https://github.com/MicrosoftLearning/mslearn-github-copilot-dev.git
SPECKIT_SRC=git+https://github.com/github/spec-kit.git
VSCODE_APP="/Applications/Visual Studio Code.app"
VSCODE_EXTS="ms-dotnettools.csdevkit ms-python.python"

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN: %s\033[0m\n' "$*" >&2; }

# first x.y[.z] in stdin
extract_ver() { grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1; }

# version_ge A B -> true if A >= B (dotted numeric)
version_ge() {
  local a b i x y
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for ((i = 0; i < 3; i++)); do
    x=${a[i]:-0}; y=${b[i]:-0}
    if ((10#$x > 10#$y)); then return 0; fi
    if ((10#$x < 10#$y)); then return 1; fi
  done
  return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

load_brew() {
  if ! have brew; then
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if [ -x "$b" ]; then eval "$("$b" shellenv)"; break; fi
    done
  fi
}

refresh_path() {
  load_brew
  export PATH="$HOME/.local/bin:$PATH"
  if [ -d /usr/local/share/dotnet ]; then export PATH="/usr/local/share/dotnet:$PATH"; fi
}

code_cmd() {
  if have code; then echo code; return; fi
  local c="$VSCODE_APP/Contents/Resources/app/bin/code"
  if [ -x "$c" ]; then echo "$c"; fi
}

git_ver()    { git --version 2>/dev/null | extract_ver; }
python_ver() { python3 --version 2>/dev/null | extract_ver; }
has_sdk()    { dotnet --list-sdks 2>/dev/null | grep -qE "^$1\."; }

# ----------------------------------------------------------------------------- install

brew_install() { # brew_install [--cask] name
  echo "  - brew install $*"
  brew install "$@" || warn "brew install $* failed; the final check shows whether it matters."
}

install_all() {
  step "Homebrew"
  load_brew
  if ! have brew; then
    echo "Homebrew is required. Install it first (asks for your password), then re-run:"
    # shellcheck disable=SC2016  # printed literally for the user to copy
    echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    exit 1
  fi
  brew update

  step "Installing missing tools"
  # Apple's /usr/bin/git is older than 2.48, so install Homebrew git if needed.
  v=$(git_ver); if [ -z "$v" ] || ! version_ge "$v" 2.48; then brew_install git; fi
  v=$(python_ver); if [ -z "$v" ] || ! version_ge "$v" 3.11; then brew_install python; fi
  have uv || brew_install uv
  if [ -d "$VSCODE_APP" ]; then echo "  - VS Code already in /Applications"; else brew_install --cask visual-studio-code; fi
  # .NET casks are .pkg installers: macOS will ask for your password.
  has_sdk 9 || brew_install --cask dotnet-sdk@9
  has_sdk 8 || brew_install --cask dotnet-sdk@8
  have copilot || brew_install --cask copilot-cli
  refresh_path

  step "NuGet: ensure nuget.org is a package source"
  if have dotnet; then
    if dotnet nuget list source | grep -q 'api.nuget.org/v3/index.json'; then
      echo "  nuget.org already configured."
    else
      dotnet nuget add source https://api.nuget.org/v3/index.json -n nuget.org
    fi
  else
    warn "dotnet not found; open a new terminal and re-run."
  fi

  step "VS Code extensions"
  local code; code=$(code_cmd)
  if [ -n "$code" ]; then
    for e in $VSCODE_EXTS; do echo "  - $e"; "$code" --install-extension "$e" --force; done
  else
    warn "VS Code CLI not found; install the extensions from the Extensions view."
  fi

  step "Spec Kit: Specify CLI (via uv)"
  if have uv; then
    uv tool install specify-cli --force --from "$SPECKIT_SRC"
    uv tool update-shell || true
  else
    warn "uv not found; skipping Specify CLI."
  fi

  step "Git identity"
  if [ -z "$(git config --global user.name)" ]; then
    read -r -p "  Git user.name (e.g. Jane Doe): " n; [ -n "$n" ] && git config --global user.name "$n"
  fi
  if [ -z "$(git config --global user.email)" ]; then
    read -r -p "  Git user.email (your GitHub email or its noreply address): " m; [ -n "$m" ] && git config --global user.email "$m"
  fi
  echo "  user.name=$(git config --global user.name)  user.email=$(git config --global user.email)"
}

# ----------------------------------------------------------------------------- smoke test

SMOKE_DIR=""
cleanup() { if [ -n "$SMOKE_DIR" ]; then rm -rf "$SMOKE_DIR"; fi; }
trap cleanup EXIT

smoke_test() {
  step "Smoke test: clone lab repo, build a C# lab, run a Python lab's tests"
  for t in git dotnet python3; do have "$t" || { warn "$t not on PATH; smoke test skipped."; return 1; }; done
  SMOKE_DIR=$(mktemp -d)
  git clone --depth 1 --quiet "$LAB_REPO" "$SMOKE_DIR/repo" || { warn "git clone failed (network/proxy?)."; return 1; }
  local ok=0
  if dotnet build "$SMOKE_DIR/repo/LabFiles/02-analyze-document-code/AccelerateDevGHCopilot/src/Library.Console/Library.Console.csproj" --nologo -v quiet; then
    echo "  C# lab builds."
  else
    warn "C# lab build FAILED."; ok=1
  fi
  if (cd "$SMOKE_DIR/repo/LabFiles/02-python-analyze-document-code/AccelerateDevGHCopilot/library" && python3 -m unittest discover tests 2>&1 | tail -n 3; exit "${PIPESTATUS[0]}"); then
    echo "  Python lab tests pass."
  else
    warn "Python lab tests FAILED."; ok=1
  fi
  return $ok
}

# ----------------------------------------------------------------------------- verification

FAILED=0
result() { # status item detail
  local color='\033[32m'
  case "$1" in FAIL) color='\033[31m'; FAILED=$((FAILED + 1)) ;; WARN) color='\033[33m' ;; esac
  printf "  ${color}[%-4s] %-38s %s\033[0m\n" "$1" "$2" "$3"
}

check_min() { # item version min
  if [ -n "$2" ] && version_ge "$2" "$3"; then result OK "$1" "$2"; else result FAIL "$1" "found: ${2:-not found}"; fi
}

check_all() {
  step "Environment check"
  refresh_path

  check_min "Git >= 2.48" "$(git_ver)" 2.48
  if [ -n "$(git config --global user.name)" ] && [ -n "$(git config --global user.email)" ]; then
    result OK "Git user.name / user.email" "$(git config --global user.name) <$(git config --global user.email)>"
  else
    result FAIL "Git user.name / user.email" "not set"
  fi

  local code; code=$(code_cmd)
  if [ -n "$code" ]; then
    check_min "VS Code >= 1.116" "$("$code" --version 2>/dev/null | head -n1 | extract_ver)" 1.116
    local exts; exts=$("$code" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]')
    for e in $VSCODE_EXTS; do
      if echo "$exts" | grep -qx "$e"; then result OK "VS Code ext $e" installed; else result FAIL "VS Code ext $e" "not installed"; fi
    done
  else
    result FAIL "VS Code >= 1.116" "not found"
  fi

  if has_sdk 9 || dotnet --list-sdks 2>/dev/null | grep -qE '^(1[0-9])\.'; then
    result OK ".NET SDK >= 9" "$(dotnet --list-sdks | awk '{print $1}' | tr '\n' ' ')"
  else
    result FAIL ".NET SDK >= 9" "not found"
  fi
  for m in 8 9; do
    if dotnet --list-runtimes 2>/dev/null | grep -qE "^Microsoft\.NETCore\.App $m\." &&
       dotnet --list-runtimes 2>/dev/null | grep -qE "^Microsoft\.AspNetCore\.App $m\."; then
      result OK ".NET $m runtime (+ASP.NET Core)" installed
    else
      result FAIL ".NET $m runtime (+ASP.NET Core)" "missing: brew install --cask dotnet-sdk@$m"
    fi
  done
  if dotnet nuget list source 2>/dev/null | grep -q 'api.nuget.org/v3/index.json'; then
    result OK "NuGet source nuget.org" configured
  else
    result FAIL "NuGet source nuget.org" missing
  fi

  check_min "Python >= 3.11 (python3)" "$(python_ver)" 3.11
  check_min "uv" "$(uv --version 2>/dev/null | extract_ver)" 0.1
  if have specify; then result OK "Specify CLI (Spec Kit)" "$(command -v specify)"; else result FAIL "Specify CLI (Spec Kit)" "not on PATH (open a new terminal)"; fi
  check_min "GitHub Copilot CLI" "$(copilot --version 2>/dev/null | extract_ver)" 0.0
  result WARN "SQL Server LocalDB" "not available on macOS; see README (LAB_AK_14)"
}

manual_steps() {
  step "Manual steps (need your GitHub login, cannot be scripted)"
  cat <<'EOF'
  1. Open a NEW terminal (PATH changed) and restart VS Code.
  2. Check your Copilot plan: https://github.com/settings/copilot
     (Free plan has tight monthly limits; the Spec Kit / agent labs use a lot of requests.)
  3. VS Code: click the Copilot icon in the Status Bar -> "Set up Copilot" / Sign in
     -> authorize in the browser. Then View -> Chat should open the Copilot Chat view.
  4. Terminal:  copilot login     (browser sign-in; needed for LAB_AK_00 SDK and LAB_AK_16)
     Then run:  copilot           and send a short prompt to confirm it answers.
  5. Python labs: let VS Code create a virtual env (Command Palette -> "Python: Create
     Environment") before configuring pytest; Homebrew Python blocks global pip installs.
EOF
}

# ----------------------------------------------------------------------------- main

if [ "$(uname -s)" != "Darwin" ]; then echo "This script is for macOS. Use setup-windows.ps1 on Windows." >&2; exit 2; fi

[ "$CHECK_ONLY" -eq 1 ] || install_all

SMOKE_RC=0
if [ "$SMOKE" -eq 1 ]; then smoke_test; SMOKE_RC=$?; fi

check_all
if [ "$SMOKE" -eq 1 ]; then
  if [ "$SMOKE_RC" -eq 0 ]; then result OK "Smoke test (C# build + Python tests)" passed
  else result FAIL "Smoke test (C# build + Python tests)" "see warnings above"; fi
fi
manual_steps

if [ "$FAILED" -gt 0 ]; then
  printf '\n\033[31m%s check(s) failed. Fix them, open a NEW terminal, and re-run with --check-only.\033[0m\n' "$FAILED"
  exit 1
fi
printf '\n\033[32mAll automated checks passed. Finish the manual steps above and you are ready.\033[0m\n'
