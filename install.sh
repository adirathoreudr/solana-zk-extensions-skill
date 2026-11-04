#!/usr/bin/env bash
# install.sh — solana-zk-extensions-skill
# Installs Solana CLI, Anchor CLI, Light Protocol SDKs, and a local Photon Indexer setup.
# Idempotent: safe to re-run, skips anything already installed.

set -euo pipefail

# Versions the skill's templates were compile-checked against. Keep these in sync
# with skill/zk_compression.md §1 and skill/transfer_hooks.md §1.
ANCHOR_VERSION="0.31.1"
LIGHT_SDK_VERSION="0.16.0"
LIGHT_JS_RANGE="^0.23"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[install]${NC} $1"; }
warn() { echo -e "${YELLOW}[install]${NC} $1"; }

# ---------------------------------------------------------------------------
# 1. Rust toolchain
# ---------------------------------------------------------------------------
if ! command -v cargo &>/dev/null; then
  log "Installing Rust toolchain..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
else
  log "Rust already installed: $(cargo --version)"
fi

# ---------------------------------------------------------------------------
# 2. Solana CLI
# ---------------------------------------------------------------------------
if ! command -v solana &>/dev/null; then
  log "Installing Solana CLI..."
  sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"
  export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"
else
  log "Solana CLI already installed: $(solana --version)"
fi

# ---------------------------------------------------------------------------
# 3. Anchor CLI (via avm — the Anchor Version Manager)
# ---------------------------------------------------------------------------
if ! command -v avm &>/dev/null; then
  log "Installing avm (Anchor Version Manager)..."
  cargo install --git https://github.com/solana-foundation/anchor avm --locked --force
fi

if command -v anchor &>/dev/null && anchor --version | grep -q " ${ANCHOR_VERSION}\$"; then
  log "Anchor CLI already installed: $(anchor --version)"
else
  log "Installing Anchor CLI ${ANCHOR_VERSION} via avm (the version the templates target)..."
  avm install "${ANCHOR_VERSION}"
  avm use "${ANCHOR_VERSION}"
fi

# ---------------------------------------------------------------------------
# 4. Node.js / npm sanity check
# ---------------------------------------------------------------------------
if ! command -v npm &>/dev/null; then
  warn "npm not found. Install Node.js 18+ before continuing (https://nodejs.org)."
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Light Protocol — TypeScript client SDKs + CLI
# ---------------------------------------------------------------------------
if [ -f "package.json" ]; then
  log "package.json detected — adding Light Protocol TypeScript SDKs to this project..."
  npm install \
    "@lightprotocol/stateless.js@${LIGHT_JS_RANGE}" \
    "@lightprotocol/compressed-token@${LIGHT_JS_RANGE}" \
    "@solana/web3.js@^1" \
    "@solana/spl-token@^0.4" \
    "@coral-xyz/anchor@${ANCHOR_VERSION}"
else
  warn "No package.json in current directory — skipping the TypeScript SDK install. Run this script from your client project (or after 'anchor init', which creates one) to add them."
fi

if ! command -v light &>/dev/null; then
  log "Installing @lightprotocol/zk-compression-cli globally..."
  npm install -g @lightprotocol/zk-compression-cli
else
  log "Light Protocol CLI already installed."
fi

# ---------------------------------------------------------------------------
# 6. Light Protocol — Rust program SDK (only if a Cargo project is present)
# ---------------------------------------------------------------------------
if [ -f "Cargo.toml" ]; then
  log "Cargo.toml detected — adding light-sdk ${LIGHT_SDK_VERSION} to this project..."
  # Pinned: newer light-sdk releases require a different Anchor major version.
  cargo add "light-sdk@=${LIGHT_SDK_VERSION}" --features anchor \
    || warn "Could not auto-add light-sdk (in an Anchor workspace, run this inside programs/<name>/). Add it manually: cargo add light-sdk@=${LIGHT_SDK_VERSION} --features anchor"
else
  warn "No Cargo.toml in current directory — skipping 'cargo add light-sdk'. Run 'anchor init <name>' first, then re-run this script inside the program directory if you want it added automatically."
fi

# ---------------------------------------------------------------------------
# 7. Local Photon Indexer + Prover (bundled with the Light test validator)
# ---------------------------------------------------------------------------
log "Local dev stack ready. To start a local validator + Photon indexer + prover:"
echo ""
echo "    light test-validator"
echo ""
echo "This exposes:"
echo "    - Solana RPC        -> http://127.0.0.1:8899"
echo "    - Photon Indexer    -> http://127.0.0.1:8784"
echo "    - Prover server     -> http://127.0.0.1:3001"
echo ""
log "For mainnet/devnet development, use a ZK-Compression-enabled RPC (Helius) instead of a local Photon instance:"
echo '    createRpc("https://devnet.helius-rpc.com?api-key=<YOUR_API_KEY>")'
echo ""
log "Install complete."
