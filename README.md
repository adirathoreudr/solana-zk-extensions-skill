# solana-zk-extensions-skill

> AI Kit Skill for safely bridging **Light Protocol ZK Compression** with **Token-2022 Extensions** on Solana.

Submitted for the **Solana AI Kit Bounty** — closing the gap between off-chain compressed state and on-chain Token-2022 CPI logic.

---

## The Problem

Two of the most important primitives in the 2026 Solana stack don't talk to each other safely out of the box:

| Primitive | What it does | The catch |
|---|---|---|
| **ZK Compression** (Light Protocol / Helius Photon Indexer) | Moves account state off-chain into validity-tree leaves, cutting rent ~99%+ for accounts with infrequent writes (loyalty tiers, NFT/game state, airdrop balances). | State only exists as a hash on-chain. Every read or write requires a fresh **validity proof** fetched from an indexer (Photon), and that proof is tied to a specific **state root** that goes stale within seconds.
| **Token-2022 Extensions** (Transfer Hooks, Confidential Transfers) | Lets a token enforce arbitrary on-chain logic (KYC, royalties, tier-gating) on every transfer via a CPI into your program. | The hook's `execute` instruction is invoked **synchronously**, with a fixed account list resolved via `ExtraAccountMetaList`. It has no RPC access and cannot fetch a Photon proof mid-transfer.

**The friction:** a hook that wants to gate a transfer on compressed state (e.g. *"only let this wallet transfer if their compressed loyalty-tier account says VIP"*) can't just reach out to Light Protocol's system program inside `execute` — `ExtraAccountMetaList` only resolves **pubkeys via seeds**, not arbitrary proof blobs, and there is exactly one validity proof allowed per instruction. Get the routing wrong and you end up with double-spendable compressed leaves, stale-root replay, or a hook that silently no-ops because a "required" extra account was actually skippable.

There was no AI context that taught an agent how to wire this correctly. This skill is that context.

## What's Inside

```
solana-zk-extensions-skill/
├── README.md
├── install.sh
└── skill/
    ├── SKILL.md                       # master router — progressive loading logic
    ├── zk_compression.md              # Light Protocol compressed PDA templates + Photon RPC
    ├── transfer_hooks.md              # Token-2022 transfer hook + compressed-state gating
    ├── security_rules.md              # non-negotiable guardrails for any generated code
    └── agents/
        └── python_ts_client_agent.md  # off-chain proof-fetch + tx-submission client template
```

`skill/SKILL.md` is the entry point any agent should read first. It decides which of the other files to load based on what the user is actually asking for, so the agent never has to load the entire cryptographic surface area just to answer a simple question.

## Install

```bash
git clone https://github.com/<your-org>/solana-zk-extensions-skill.git
cd solana-zk-extensions-skill
chmod +x install.sh
./install.sh
```

`install.sh` installs (idempotently — safe to re-run):
- Rust + the Solana CLI
- Anchor CLI (via `avm`)
- `light-sdk` (Rust, added to a Cargo project if one is present) + `@lightprotocol/zk-compression-cli`
- `@lightprotocol/stateless.js` and `@lightprotocol/compressed-token` (TypeScript client SDKs)
- A local Photon Indexer + prover, via `light test-validator`

## Install Globally (Any CLI Agent)

```bash
npx skills add ./solana-zk-extensions-skill --skill solana-zk-extensions-skill -g
```

Installs the skill **globally** (user-level, not just this project) so it's available to any CLI agent — Claude Code, Codex CLI, Cursor, OpenCode — across every repo you open, not just this one. Use `./solana-zk-extensions-skill` as a local path before pushing to GitHub; once pushed, swap it for `<your-github-username>/solana-zk-extensions-skill`

## Run It

This is a **skill**, not a standalone app — it's meant to be loaded into an AI coding agent (Claude Code, an MCP-connected IDE agent, or any AI Kit–compatible runner) as context.

1. Point your agent's skill loader at `skill/SKILL.md`.
2. Ask for what you need, e.g.:
   - *"Build an Anchor program that stores a user's loyalty tier as a compressed PDA."*
   - *"Add a Token-2022 transfer hook that blocks transfers for non-VIP wallets, checked against compressed state."*
   - *"Write the TypeScript client that fetches the validity proof and submits the gated transfer."*
3. The router in `SKILL.md` loads only the relevant sub-file(s), and `security_rules.md` is loaded automatically for every code-generation request — non-optional, by design.

To validate generated programs locally:

```bash
light test-validator        # local validator + Photon indexer + prover, ports 8899 / 8784 / 3001
anchor build
anchor deploy
```

## License

MIT License

Copyright (c) 2026 solana-zk-extensions-skill contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
