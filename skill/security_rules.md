# Security Rules

**Read this before generating, editing, or reviewing any code under this skill.**
These rules are not suggestions — refuse to ship code that violates them, and say
why, rather than silently "softening" the rule to satisfy a request.

## Rule 1 — Never allow double-spending of compressed state

A compressed account is identified by a **leaf hash**, not a fixed address. Spending
it means proving the current hash exists, then letting the Light System Program
write a new hash (or nothing, for a close) at the same position in the state tree.

- Always use `LightAccount::new_mut` (not `new_init`) when modifying an account that
  already exists. `new_init` proves non-existence in an *address* tree — using it on
  an existing account either fails safely or, worse, creates a colliding logical
  state if address derivation is also wrong. Verify which one you need before writing
  the instruction; do not default to whichever compiles.
- Never accept a client-supplied `CompressedAccountMeta` without independently
  re-deriving the address/seed it claims to represent. If the program logic assumes
  `account_meta` corresponds to a specific owner or PDA seed, assert that on-chain —
  do not trust the client to have packed the right one.
## Rule 2 — Enforce valid fresh state roots
  reuse a single `ValidityProof` object across two separate CPIs into the Light
  System Program in the same instruction unless using the documented
  `cpi-context` feature for batched multi-program operations — anything else is
  unverified by the proof and is a silent bypass.

## Rule 2 — Enforce valid, fresh state roots

A validity proof is only meaningful against the **root it was generated for**. Roots
roll forward as the tree is written by other transactions.

- Always fetch the validity proof as the **last off-chain step** before signing and
  sending the transaction — never cache a proof and reuse it across retries or across
  multiple transaction attempts. A retry must re-fetch.
- On-chain, never write logic that skips or weakens the Light System Program's root
  check (e.g. by manually constructing a `CompressedAccountMeta` with a root index
  the proof wasn't actually generated against). If you find yourself hand-writing a
  root index instead of taking it from the RPC response, stop — that's the bug.
- For any custom "attestation" pattern that bridges compressed-state verification to
  a later instruction (as in `transfer_hooks.md`), bound the attestation's validity to
  a small number of slots (1-2) and check that bound on-chain with `Clock::get()`.
  An attestation with no expiry is a stale-root bug wearing a disguise.

## Rule 3 — Prevent signature and instruction replay

- Any attestation, voucher, or cached-verification account that authorizes a
  follow-on action **must be consumed (closed, zeroed, or flagged) in the same
  instruction that uses it**, atomically with the action it authorizes. Never check a
  flag and clear it in two separate, independently-callable instructions — that
  creates a window where an attacker can use the flag twice across two transactions.
- Never derive an attestation PDA from data the attacker fully controls without also
  binding it to a signer. Seed attestation PDAs from `(purpose, owner, mint)` at
  minimum, and require `owner` to be a real `Signer` somewhere in the transaction,
  not just an `UncheckedAccount` reference — see `transfer_hooks.md` §3-5 for the
  reference shape, but verify the signer constraint explicitly in generated code.
- Do not reuse a `recent_blockhash` or proof artifact across transactions as a
  substitute for a nonce. If true offline/durable-nonce signing is required, use
  Solana's native `nonce` accounts explicitly — don't invent an ad hoc replacement.

## Rule 4 — Transfer hook validations must be non-bypassable

- Every `execute_transfer` (or equivalently named) hook entrypoint must call
  `ExtraAccountMetaList::check_account_infos::<ExecuteInstruction>(...)` before
  trusting any extra account. Skipping this check, or wrapping it in a condition that
  can evaluate false, defeats the entire interface's safety model.
- Never mark a required extra account `is_signer: false, is_writable: false` and then
  rely on its *contents* for an authorization decision unless you also verify its
  **owner program** and **PDA seeds** on-chain. A read-only account with no
  owner/seed check can be substituted by an attacker with a fake account holding
  whatever data they want.
- If a hook program also implements a `fallback` instruction (pre-Anchor-0.30 pattern)
  for routing the native Token-2022 CPI, that fallback must dispatch on the exact SPL
  interface discriminator (`hash("spl_transfer_hook_interface:execute")`), never on
  Anchor's default `global:` namespace — confusing the two silently no-ops the hook
  instead of failing loudly. Prefer the `#[interface(spl_transfer_hook_interface::execute)]`
  attribute (Anchor ≥0.30) over hand-rolled fallback routing wherever possible.
- Gating logic must fail closed. If a required attestation/extra account is missing,
  stale, or mismatched, the instruction must error — never default to "allow" when a
  check can't be completed.

## Rule 5 — General hygiene for this skill's output

- Do not generate code that silently swallows a `Result` from a CPI into the Light
  System Program or the Token-2022 program. Propagate errors with `?`.
- Do not hardcode mainnet program IDs as placeholders without labeling them clearly
  as such; a copy-pasted placeholder ID deployed by mistake is a real failure mode.
- When in doubt about whether a generated pattern is exploitable, say so explicitly
  in the response rather than presenting unverified code as production-ready.
