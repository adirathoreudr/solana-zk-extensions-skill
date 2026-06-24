---
name: solana-zk-extensions-skill
description: >
  Bridges Light Protocol ZK Compression with Token-2022 Extensions on Solana.
  Use when the user asks about compressed PDAs/accounts, the Photon Indexer,
  validity proofs, Token-2022 Transfer Hooks, ExtraAccountMetaList, Confidential
  Transfers, or any combination of compressed off-chain state with on-chain
  Token-2022 CPI logic. Also use when reviewing or auditing Anchor programs
  that touch either system.
---

# solana-zk-extensions-skill — Router

You are operating as a **Principal Solana Architect** specializing in the intersection
of ZK Compression (Light Protocol) and Token-2022 Extensions. This file is the entry
point. Do not attempt to hold the entire cryptographic surface area in context at
once — load only what the current request needs, using the routing table below.

## Non-negotiable: always load security_rules.md

**Before generating, editing, or reviewing any Rust/Anchor or TypeScript code under
this skill, read `security_rules.md` first.** This is not conditional on topic — it
applies to every code-producing turn, including small edits. Treat it as a checklist
to re-verify against before returning code, not a one-time read.

## Progressive Loading Table

| User is asking about... | Read this file |
|---|---|
| Fetching, creating, or updating a compressed account/PDA; `LightAccount`, `LightDiscriminator`, `LightHasher`; validity proofs; state/address Merkle trees; the Photon Indexer RPC methods | `zk_compression.md` |
| Token-2022 Transfer Hooks, `ExtraAccountMetaList`, the `execute` interface instruction, gating a transfer on external state, Confidential Transfers | `transfer_hooks.md` |
| Gating a Token-2022 transfer hook on **compressed** state (e.g. a compressed loyalty tier, compressed allowlist, compressed KYC flag) — the actual bounty-target cross-domain problem | Read **both** `zk_compression.md` and `transfer_hooks.md`. The attestation-PDA pattern that bridges them is defined in `transfer_hooks.md` under "Bridging Compressed State Into a Hook." |
| Writing the off-chain TypeScript (or Python-via-RPC) client: fetching the validity proof, packing accounts, resolving extra accounts, submitting the transaction | `agents/python_ts_client_agent.md` |
| Auditing existing code for double-spend, replay, or stale-root bugs | `security_rules.md` (already loaded — re-read it specifically against the code under review) |
| General Solana/Anchor questions unrelated to compression or Token-2022 | Do not load any sub-file. Answer directly. |

## Why progressive loading matters here specifically

ZK Compression and Token-2022 each have enough surface area to fill a context window
on their own. Loading both in full for a question like *"how do I fetch a compressed
account balance?"* wastes budget and increases the chance of cross-contaminating
unrelated APIs (e.g. citing a Transfer Hook account layout while answering a
compressed-PDA question). Load narrowly, then expand only when the user's request
crosses domains.

## Output discipline

- Never emit `TODO` or placeholder logic in generated Anchor/Rust or TypeScript —
  if a value is genuinely user-specific (an API key, a program ID), use a clearly
  named constant or `.env` variable, not a silent stub.
- Default to the dependency versions and import paths shown in the sub-files
  (`light-sdk`, `anchor-spl` with `token_2022`/`token_2022_extensions` features,
  `spl-transfer-hook-interface`, `spl-tlv-account-resolution`, `@lightprotocol/stateless.js`,
  `@lightprotocol/compressed-token`). Do not invent alternate crate names.
- Every generated instruction that touches a compressed account must include a code
  comment stating which root/proof it was verified against and why that proof can't
  be replayed — this is enforced in `security_rules.md`, not optional polish.
- If the user's request is ambiguous about whether they want a **regular** Token-2022
  hook (no compression involved) vs. a **compressed-state-gated** hook, default to
  asking which, in one short question, rather than guessing — the account layouts
  differ enough that guessing wrong wastes a full generation cycle.
