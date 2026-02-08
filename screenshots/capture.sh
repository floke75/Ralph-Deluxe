#!/usr/bin/env bash
set -euo pipefail

# capture.sh — One-command dashboard screenshot capture.
#
# Detects Playwright + Chromium, builds Tailwind CSS if stale,
# runs the Playwright screenshot script, then exits.
#
# Usage:
#   ./screenshots/capture.sh          # from project root
#   bash screenshots/capture.sh       # also works
#
# Environment overrides (all optional):
#   PLAYWRIGHT_MODULE   — path to playwright index.mjs
#   CHROMIUM_BIN        — path to chromium executable
#   BROWSERS_PATH       — playwright browser cache dir
#   SCREENSHOT_PORT     — HTTP server port (default: 8089)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Color helpers ---
info()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
ok()    { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[0;33m%s\033[0m\n' "$*"; }
fail()  { printf '\033[0;31m%s\033[0m\n' "$*" >&2; exit 1; }

# --- 1. Detect Playwright module ---
find_playwright_module() {
  # Explicit override
  if [[ -n "${PLAYWRIGHT_MODULE:-}" ]] && [[ -f "$PLAYWRIGHT_MODULE" ]]; then
    echo "$PLAYWRIGHT_MODULE"; return
  fi

  # Local node_modules (npm install playwright)
  local local_mjs="$PROJECT_ROOT/node_modules/playwright/index.mjs"
  if [[ -f "$local_mjs" ]]; then
    echo "$local_mjs"; return
  fi

  # Global npm prefix
  local global_prefix
  global_prefix="$(npm root -g 2>/dev/null || true)"
  if [[ -n "$global_prefix" ]]; then
    local global_mjs="$global_prefix/playwright/index.mjs"
    if [[ -f "$global_mjs" ]]; then
      echo "$global_mjs"; return
    fi
  fi

  # Common global locations
  for dir in /opt/node22/lib/node_modules /usr/local/lib/node_modules /usr/lib/node_modules; do
    if [[ -f "$dir/playwright/index.mjs" ]]; then
      echo "$dir/playwright/index.mjs"; return
    fi
  done

  return 1
}

# --- 2. Detect Chromium binary ---
find_chromium() {
  # Explicit override
  if [[ -n "${CHROMIUM_BIN:-}" ]] && [[ -x "$CHROMIUM_BIN" ]]; then
    echo "$CHROMIUM_BIN"; return
  fi

  local browsers_path="${BROWSERS_PATH:-${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}}"

  # Search for chromium in the playwright browser cache (newest revision first)
  for chromium_dir in "$browsers_path"/chromium-*/chrome-linux/chrome; do
    if [[ -x "$chromium_dir" ]]; then
      echo "$chromium_dir"; return
    fi
  done

  # Fallback: system chromium
  for bin in chromium chromium-browser google-chrome; do
    if command -v "$bin" &>/dev/null; then
      command -v "$bin"; return
    fi
  done

  return 1
}

# --- 3. Build Tailwind CSS if stale ---
build_tailwind_if_needed() {
  local css_out="$SCRIPT_DIR/tailwind-generated.css"
  local tw_config="$SCRIPT_DIR/tailwind.config.js"
  local dashboard="$PROJECT_ROOT/.ralph/dashboard.html"

  # Rebuild if: CSS doesn't exist, or dashboard is newer than CSS, or config is newer
  if [[ ! -f "$css_out" ]] \
    || [[ "$dashboard" -nt "$css_out" ]] \
    || [[ "$tw_config" -nt "$css_out" ]]; then
    info "Building Tailwind CSS..."

    # Ensure tailwindcss is available
    if ! npx tailwindcss --help &>/dev/null 2>&1; then
      info "Installing tailwindcss..."
      npm install --save-dev tailwindcss@3 --prefix "$PROJECT_ROOT" 2>&1 | tail -1
    fi

    # Create temp input file
    local tmp_input
    tmp_input="$(mktemp)"
    cat > "$tmp_input" <<'CSS'
@tailwind base;
@tailwind components;
@tailwind utilities;
CSS

    # Run from screenshots/ dir so content paths in tailwind.config.js resolve correctly
    (cd "$SCRIPT_DIR" && npx tailwindcss \
      -i "$tmp_input" \
      -o "$css_out" \
      -c "$tw_config" \
      --minify 2>&1 | grep -v "Browserslist" || true)

    rm -f "$tmp_input"
    ok "Tailwind CSS built ($(wc -c < "$css_out" | tr -d ' ') bytes)"
  else
    info "Tailwind CSS is up to date"
  fi
}

# --- 4. Run screenshot script ---
run_screenshots() {
  local playwright_module="$1"
  local chromium_bin="$2"
  local browsers_path="${BROWSERS_PATH:-${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}}"
  local port="${SCREENSHOT_PORT:-8089}"

  info "Running Playwright screenshot capture..."
  PLAYWRIGHT_MODULE="$playwright_module" \
  CHROMIUM_BIN="$chromium_bin" \
  PLAYWRIGHT_BROWSERS_PATH="$browsers_path" \
  SCREENSHOT_PORT="$port" \
    node "$SCRIPT_DIR/take-screenshots.mjs"
}

# --- Main ---
main() {
  info "=== Ralph Deluxe — Dashboard Screenshot Capture ==="

  # Detect environment
  local playwright_module chromium_bin

  if ! playwright_module="$(find_playwright_module)"; then
    fail "Could not find Playwright. Install it: npm install --save-dev playwright"
  fi
  ok "Playwright: $playwright_module"

  if ! chromium_bin="$(find_chromium)"; then
    fail "Could not find Chromium. Install browsers: npx playwright install chromium"
  fi
  ok "Chromium:   $chromium_bin"

  # Build CSS
  build_tailwind_if_needed

  # Capture
  run_screenshots "$playwright_module" "$chromium_bin"

  ok "=== Screenshots saved to screenshots/ ==="
}

main "$@"
