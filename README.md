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
├── LICENSE
├── install.sh                         # toolchain + SDK installer (pinned versions)
├── .env.example                       # copy to .env — HELIUS_API_KEY etc.
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
git clone https://github.com/adirathoreudr/solana-zk-extensions-skill.git
cd solana-zk-extensions-skill
chmod +x install.sh
./install.sh
```

`install.sh` installs (idempotently — safe to re-run):
- Rust + the Solana CLI
- Anchor CLI **0.31.1** (via `avm`)
- `@lightprotocol/zk-compression-cli` (the `light` command, which bundles a local Photon Indexer + prover via `light test-validator`)
- `light-sdk` **0.16.0** with the `anchor` feature, added to the Cargo project in the current directory, if there is one
- `@lightprotocol/stateless.js` / `@lightprotocol/compressed-token` **^0.23**, `@solana/web3.js`, `@solana/spl-token`, `@coral-xyz/anchor` **0.31.1**, added to the `package.json` in the current directory, if there is one

Then copy `.env.example` to `.env` and set `HELIUS_API_KEY`.

### Versions

The templates target **one** dependency set: Anchor 0.31.1, `light-sdk` 0.16 (Light V1 CPI), `spl-transfer-hook-interface` / `spl-tlv-account-resolution` 0.9, and `@lightprotocol/stateless.js` ^0.23. The Rust code blocks compile (`cargo check`, including `--features idl-build`). The TypeScript blocks type-check under `tsc --strict` against the generated IDL. Upgrading any one of these on its own will break the others (newer `light-sdk` releases require Anchor 1.x), so treat the set as a unit.

## Install Globally (Any CLI Agent)

```bash
npx skills add adirathoreudr/solana-zk-extensions-skill --skill solana-zk-extensions-skill -g
```

Installs the skill **globally** (user-level, not just this project), so it's available to any CLI agent (Claude Code, Codex CLI, Cursor, OpenCode) in every repo you open. To install from a local clone instead (e.g. while editing the skill), pass the path: `npx skills add ./solana-zk-extensions-skill --skill solana-zk-extensions-skill -g`.

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

MIT — see [`LICENSE`](LICENSE).
