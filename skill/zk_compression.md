# zk_compression.md

Reference templates for defining and operating on **Light Protocol compressed accounts**
inside an Anchor program, plus the off-chain RPC calls (Photon Indexer, via Helius or a
local `light test-validator`) needed to read state and fetch validity proofs.

## 1. Dependencies

These versions are a set that compiles together. `light-sdk` 0.16 is built against
`anchor-lang` 0.31.1. Do not bump one without the others.

`programs/zk_loyalty/Cargo.toml`:

```toml
[dependencies]
anchor-lang = { version = "0.31.1", features = ["init-if-needed"] }
light-sdk = { version = "0.16.0", features = ["anchor"] }

[features]
idl-build = ["anchor-lang/idl-build", "light-sdk/idl-build"]
```

- `features = ["anchor"]` is required. Without it `light-sdk` derives plain `borsh`
  traits, and its types (`ValidityProof`, `CompressedAccountMeta`, …) can't be used
  as Anchor instruction arguments.
- `init-if-needed` is only needed by the attestation account in `transfer_hooks.md`.

TypeScript client:

```bash
npm install @lightprotocol/stateless.js@^0.23 @lightprotocol/compressed-token@^0.23 @solana/web3.js@^1
```

> **V1 vs V2.** The program below uses Light's **V1** CPI path (`light_sdk::cpi::v1`),
> which is the default for `light-sdk` 0.16. Published `@lightprotocol/stateless.js`
> ≥ 0.23 defaults to **V2** account layouts, so the client must build the V1 system
> accounts explicitly with `getLightSystemAccountMetasLegacy` (see
> `agents/python_ts_client_agent.md`). If the client and program pick different
> versions, the Light System Program CPI fails with an account-index error.

## 2. Defining a Compressed Account

A compressed account is a regular Rust struct with the `LightDiscriminator` derive.
The 8-byte discriminator is stored next to the data in the leaf, not inside it.
`light_sdk::LightAccount` (the default, SHA-256 variant) hashes the **entire**
borsh-serialized struct into the leaf's data hash. Every field is committed to by
the proof, so a client cannot change any field without the proof failing.

```rust
use anchor_lang::prelude::*;
use light_sdk::LightDiscriminator;

#[derive(Clone, Debug, Default, AnchorSerialize, AnchorDeserialize, LightDiscriminator)]
pub struct LoyaltyTier {
    pub owner: Pubkey,
    pub tier: u8,               // 0 = none, 1 = standard, 2 = vip
    pub points: u64,
    pub last_updated_slot: u64,
}
```

> Only use `LightHasher` + `#[hash]` with the Poseidon variant
> (`light_sdk::account::poseidon::LightAccount`, `poseidon` feature), and only when
> you need ZK-friendly hashing over individual fields. There, `#[hash]` marks fields
> wider than 31 bytes (such as `Pubkey`) that must be hashed down to the BN254 field.
> For the SHA-256 default, `#[hash]` is not used.

## 3. Program Skeleton

`programs/zk_loyalty/src/lib.rs`:

```rust
use anchor_lang::prelude::*;
use light_sdk::{
    account::LightAccount,
    address::v1::derive_address,
    cpi::{
        v1::{CpiAccounts, LightSystemProgramCpi},
        InvokeLightSystemProgram, LightCpiInstruction,
    },
    derive_light_cpi_signer,
    error::LightSdkError,
    instruction::{account_meta::CompressedAccountMeta, PackedAddressTreeInfo, ValidityProof},
    CpiSigner, LightDiscriminator,
};

// PLACEHOLDER program ID: replace with your own (`anchor keys list`) before deploying.
declare_id!("ZkExtPda11111111111111111111111111111111111");

// CPI signer this program uses to authorize calls into the Light System Program.
// Derived from THIS program's own ID — not the Light System Program's ID.
pub const LIGHT_CPI_SIGNER: CpiSigner =
    derive_light_cpi_signer!("ZkExtPda11111111111111111111111111111111111");

// PLACEHOLDER: the only key allowed to change tiers (e.g. your loyalty backend's
// signer). Replace before deploying — see security_rules.md, Rule 5.
pub const LOYALTY_AUTHORITY: Pubkey = pubkey!("LoyaLtyAuthority111111111111111111111111111");

#[derive(Clone, Debug, Default, AnchorSerialize, AnchorDeserialize, LightDiscriminator)]
pub struct LoyaltyTier {
    pub owner: Pubkey,
    pub tier: u8,
    pub points: u64,
    pub last_updated_slot: u64,
}

#[program]
pub mod zk_loyalty {
    use super::*;

    /// Creates the owner's compressed LoyaltyTier at the deterministic address
    /// derived from seeds `["loyalty", owner]`. The proof is a NON-INCLUSION proof
    /// for that address (fetched client-side with
    /// `rpc.getValidityProofV0([], [{ address, tree, queue }])`), so each owner
    /// can only ever have one LoyaltyTier.
    pub fn create_loyalty_tier<'info>(
        ctx: Context<'_, '_, '_, 'info, CreateLoyaltyTier<'info>>,
        proof: ValidityProof,
        address_tree_info: PackedAddressTreeInfo,
        output_state_tree_index: u8,
    ) -> Result<()> {
        let owner = ctx.accounts.owner.key();

        let light_cpi_accounts = CpiAccounts::new(
            ctx.accounts.fee_payer.as_ref(),
            ctx.remaining_accounts,
            crate::LIGHT_CPI_SIGNER,
        );

        // Verified against: the address-tree root at `address_tree_info.root_index`,
        // taken from the RPC response — never hand-written (security_rules.md, Rule 2).
        // Not replayable: once the address is inserted, a second non-inclusion
        // proof for it cannot exist.
        let address_tree_pubkey = address_tree_info
            .get_tree_pubkey(&light_cpi_accounts)
            .map_err(|e| ProgramError::from(LightSdkError::from(e)))?;
        let (address, address_seed) = derive_address(
            &[b"loyalty", owner.as_ref()],
            &address_tree_pubkey,
            &crate::ID,
        );
        let new_address_params = address_tree_info.into_new_address_params_packed(address_seed);

        let mut loyalty_account = LightAccount::<LoyaltyTier>::new_init(
            &crate::ID,
            Some(address),
            output_state_tree_index,
        );
        loyalty_account.owner = owner;
        loyalty_account.tier = 0;
        loyalty_account.points = 0;
        loyalty_account.last_updated_slot = Clock::get()?.slot;

        LightSystemProgramCpi::new_cpi(crate::LIGHT_CPI_SIGNER, proof)
            .with_new_addresses(&[new_address_params])
            .with_light_account(loyalty_account)?
            .invoke(light_cpi_accounts)?;

        Ok(())
    }

    /// Updates an existing compressed LoyaltyTier. Only `LOYALTY_AUTHORITY` may
    /// call this. Otherwise any wallet could promote itself to VIP.
    ///
    /// `current` must be the account's exact current contents (every field,
    /// including `last_updated_slot`), because `new_mut` hashes it to rebuild the
    /// input leaf.
    pub fn update_loyalty_tier<'info>(
        ctx: Context<'_, '_, '_, 'info, UpdateLoyaltyTier<'info>>,
        proof: ValidityProof,
        account_meta: CompressedAccountMeta,
        current: LoyaltyTier,
        new_tier: u8,
        new_points: u64,
    ) -> Result<()> {
        require!(new_tier <= 2, LoyaltyError::InvalidTier);

        // Verified against: the state-tree root at `account_meta.tree_info.root_index`,
        // from the same RPC response as `proof`. The leaf hash commits to this
        // program as owner, the address, and every field of `current`. A wrong
        // value or a forged account makes the CPI below fail.
        // Not replayable: the CPI nullifies the input leaf, so this proof can never
        // be used again.
        let mut loyalty_account =
            LightAccount::<LoyaltyTier>::new_mut(&crate::ID, &account_meta, current)?;

        loyalty_account.tier = new_tier;
        loyalty_account.points = new_points;
        loyalty_account.last_updated_slot = Clock::get()?.slot;

        let light_cpi_accounts = CpiAccounts::new(
            ctx.accounts.fee_payer.as_ref(),
            ctx.remaining_accounts,
            crate::LIGHT_CPI_SIGNER,
        );

        LightSystemProgramCpi::new_cpi(crate::LIGHT_CPI_SIGNER, proof)
            .with_light_account(loyalty_account)?
            .invoke(light_cpi_accounts)?;

        Ok(())
    }
}

#[derive(Accounts)]
pub struct CreateLoyaltyTier<'info> {
    #[account(mut)]
    pub fee_payer: Signer<'info>,
    /// The wallet the tier belongs to. Must sign, so nobody can open (and thereby
    /// pin the address of) a loyalty account on someone else's behalf.
    pub owner: Signer<'info>,
    // remaining_accounts (not declared here) carries, in order:
    //   [light system accounts (V1 layout)..., packed tree/queue accounts...]
    // Indices in `PackedAddressTreeInfo` / `CompressedAccountMeta` are relative to
    // the first packed tree account — see agents/python_ts_client_agent.md.
}

#[derive(Accounts)]
pub struct UpdateLoyaltyTier<'info> {
    #[account(mut)]
    pub fee_payer: Signer<'info>,
    #[account(address = LOYALTY_AUTHORITY @ LoyaltyError::Unauthorized)]
    pub authority: Signer<'info>,
    // remaining_accounts: same layout as CreateLoyaltyTier.
}

#[error_code]
pub enum LoyaltyError {
    #[msg("Tier must be 0 (none), 1 (standard), or 2 (vip)")]
    InvalidTier,
    #[msg("Only the loyalty authority may change a tier")]
    Unauthorized,
}
```

**Why `new_init` vs `new_mut` matters:** `new_init` proves a NEW address doesn't yet
exist (address-tree non-inclusion proof). `new_mut` proves the EXISTING leaf hash
you're about to overwrite is the real current state (state-tree inclusion proof).
Mixing these up is the most common source of "valid-looking" compressed-account bugs.
See `security_rules.md`.

**Why the owner binding holds:** the only code path that creates a `LoyaltyTier`
derives its address from `["loyalty", owner]` and requires `owner` to sign. No path
ever changes `owner` afterwards. Because the leaf hash commits to both the address and
the `owner` field, any `LoyaltyTier` leaf this program owns has an `owner` that is
genuinely bound to its address. This is the on-chain invariant that
`security_rules.md` Rule 1 asks you to state explicitly.

## 4. Reading Compressed State From the Photon Indexer (off-chain)

```typescript
import { createRpc } from "@lightprotocol/stateless.js";
import { PublicKey } from "@solana/web3.js";

// Helius exposes the Solana RPC and the Photon Indexer through one URL.
const HELIUS_RPC = `https://devnet.helius-rpc.com?api-key=${process.env.HELIUS_API_KEY}`;
const rpc = createRpc(HELIUS_RPC, HELIUS_RPC);

// LoyaltyTier borsh layout: owner (32) | tier (1) | points (8) | last_updated_slot (8)
const LOYALTY_TIER_LEN = 49;

async function fetchLoyaltyTier(owner: PublicKey, programId: PublicKey) {
  let cursor: string | undefined;
  do {
    const page = await rpc.getCompressedAccountsByOwner(programId, { cursor });
    const match = page.items.find(
      (acc) =>
        acc.data?.data?.length === LOYALTY_TIER_LEN &&
        new PublicKey(acc.data.data.subarray(0, 32)).equals(owner),
    );
    if (match) {
      // A fresh proof MUST be fetched immediately before building the transaction
      // that consumes it — see security_rules.md, Rule 2.
      const proof = await rpc.getValidityProofV0(
        [{ hash: match.hash, tree: match.treeInfo.tree, queue: match.treeInfo.queue }],
        [],
      );
      return { account: match, proof };
    }
    cursor = page.cursor ?? undefined;
  } while (cursor);
  return null;
}
```

Scanning by program owner is simple and works with either Light version. For large
programs, derive the account's address client-side instead and call
`rpc.getCompressedAccount(bn(address.toBytes()))`. Use the derivation that matches the
program's version: `deriveAddressSeedLegacy` + `deriveAddressLegacy` for the V1
`address::v1::derive_address` used above.

Local development (no Helius key needed):

```bash
light test-validator   # starts validator + Photon indexer (8784) + prover (3001)
```

```typescript
const localRpc = createRpc(); // defaults to http://127.0.0.1:8899 / :8784 / :3001
```

## 5. Key Photon / Light RPC Methods

| Method | Purpose |
|---|---|
| `getCompressedAccount(address?, hash?)` | Fetch a single compressed account by its persistent address **or** its current leaf hash (pass one, leave the other `undefined`). |
| `getCompressedAccountsByOwner(owner, { cursor? })` | List all compressed accounts a program/owner controls. Paginated, so follow `cursor`. |
| `getCompressedTokenAccountsByOwner(owner, { mint? })` | List compressed SPL/Token-2022 balances. |
| `getValidityProofV0(hashesWithTrees[], newAddressesWithTrees[])` | The single call that returns the ZK proof (plus `rootIndices` / `proveByIndices`) for any instruction touching compressed state. **Always call this last, right before signing — see security_rules.md.** (`getValidityProof(hashes[], newAddresses[])` is the older, deprecated form.) |
| `getIndexerHealth()` / `getIndexerSlot()` | Sanity-check that the indexer is healthy and caught up to a recent slot before trusting its results. |
| `getCompressionSignaturesForAccount(hash)` | Audit trail of every transaction that touched a given leaf. Useful for the double-spend checks in `security_rules.md`. |
