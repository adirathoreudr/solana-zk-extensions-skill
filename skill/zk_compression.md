# ZK Compression Reference

Reference templates for defining and operating on **Light Protocol compressed accounts**
inside an Anchor program, plus the off-chain RPC calls (Photon Indexer, via Helius or a
local `light test-validator`) needed to read state and fetch validity proofs.

## 1. Dependencies

`programs/<your-program>/Cargo.toml`:

```toml
[dependencies]
anchor-lang = "0.31.1"
light-sdk = "0.16.0"
borsh = "0.10.0"
## 2. Defining a Compressed Account

[features]
idl-build = ["anchor-lang/idl-build"]
```

TypeScript client:

```bash
npm install @lightprotocol/stateless.js @lightprotocol/compressed-token @solana/web3.js
```

## 2. Defining a Compressed Account

A compressed account is a regular Rust struct, made compressible with two derive
macros: `LightDiscriminator` (replaces Anchor's 8-byte discriminator with one that
works inside a hashed leaf) and `LightHasher` (defines which fields get hashed into
the leaf). Mark fields that should be hashed with `#[hash]`.

```rust
use anchor_lang::prelude::*;
use light_sdk::{LightDiscriminator, LightHasher};

#[derive(Clone, Debug, Default, AnchorSerialize, AnchorDeserialize, LightDiscriminator, LightHasher)]
pub struct LoyaltyTier {
    #[hash]
    pub owner: Pubkey,
    pub tier: u8,        // 0 = none, 1 = standard, 2 = vip
    pub points: u64,
    pub last_updated_slot: u64,
}
```

## 3. Program Skeleton

```rust
use anchor_lang::prelude::*;
use light_sdk::{
    cpi::{CpiAccounts, LightSystemProgramCpi, InvokeLightSystemProgram},
    instruction::{ValidityProof, PackedAccounts},
    account::LightAccount,
    address::v1::derive_address,
    derive_light_cpi_signer,
    LightDiscriminator, LightHasher,
    CpiSigner,
    compressed_account::CompressedAccountMeta,
};

declare_id!("ZkExtPda11111111111111111111111111111111111");

// CPI signer this program uses to authorize calls into the Light System Program.
// Derived from THIS program's own ID — not the Light System Program's ID.
pub const LIGHT_CPI_SIGNER: CpiSigner = derive_light_cpi_signer!("ZkExtPda11111111111111111111111111111111111");

#[derive(Clone, Debug, Default, AnchorSerialize, AnchorDeserialize, LightDiscriminator, LightHasher)]
pub struct LoyaltyTier {
    #[hash]
    pub owner: Pubkey,
    pub tier: u8,
    pub points: u64,
    pub last_updated_slot: u64,
}

#[program]
pub mod zk_loyalty {
    use super::*;

    /// Creates a new compressed LoyaltyTier account at a deterministic address
    /// derived from the owner's pubkey. Requires a proof that this address
    /// does NOT already exist in the address tree (fetched client-side via
    /// `rpc.getValidityProofV0([], [{ address, tree, queue }])`).
    pub fn create_loyalty_tier<'info>(
        ctx: Context<'_, '_, '_, 'info, LoyaltyAccounts<'info>>,
        proof: ValidityProof,
        address_tree_index: u8,
        output_state_tree_index: u8,
        owner: Pubkey,
    ) -> Result<()> {
        let (address, address_seed) = derive_address(
            &[b"loyalty", owner.as_ref()],
            &ctx.remaining_accounts[address_tree_index as usize].key(),
            &crate::ID,
        );

        let new_account_meta = light_sdk::instruction::PackedAddressTreeInfo {
            address_merkle_tree_root_index: 0, // populated by client packing — see agents/python_ts_client_agent.md
            address_merkle_tree_pubkey_index: address_tree_index,
            address_queue_pubkey_index: address_tree_index,
        };

        let mut loyalty_account = LightAccount::<'_, LoyaltyTier>::new_init(
            &crate::ID,
            Some(address),
            output_state_tree_index,
        );

        loyalty_account.owner = owner;
        loyalty_account.tier = 0;
        loyalty_account.points = 0;
        loyalty_account.last_updated_slot = Clock::get()?.slot;

        let light_cpi_accounts = CpiAccounts::new(
            ctx.accounts.fee_payer.as_ref(),
            ctx.remaining_accounts,
            crate::LIGHT_CPI_SIGNER,
        );

        LightSystemProgramCpi::new_cpi(LIGHT_CPI_SIGNER, proof)
            .with_new_addresses(&[new_account_meta])
            .with_light_account(loyalty_account)?
            .invoke(light_cpi_accounts)?;

        Ok(())
    }

    /// Updates an existing compressed LoyaltyTier. The client must supply a
    /// FRESH validity proof for the account's current hash — see
    /// security_rules.md, Rule 2 (stale-root rejection), before calling this.
    pub fn update_loyalty_tier<'info>(
        ctx: Context<'_, '_, '_, 'info, LoyaltyAccounts<'info>>,
        proof: ValidityProof,
        account_meta: CompressedAccountMeta,
        current_owner: Pubkey,
        current_tier: u8,
        current_points: u64,
        new_tier: u8,
        new_points: u64,
    ) -> Result<()> {
        require!(new_tier <= 2, LoyaltyError::InvalidTier);

        let mut loyalty_account = LightAccount::<'_, LoyaltyTier>::new_mut(
            &crate::ID,
            &account_meta,
            LoyaltyTier {
                owner: current_owner,
                tier: current_tier,
                points: current_points,
                last_updated_slot: 0, // overwritten below; input hash uses the meta's input state
            },
        )?;

        loyalty_account.tier = new_tier;
        loyalty_account.points = new_points;
        loyalty_account.last_updated_slot = Clock::get()?.slot;

        let light_cpi_accounts = CpiAccounts::new(
            ctx.accounts.fee_payer.as_ref(),
            ctx.remaining_accounts,
            crate::LIGHT_CPI_SIGNER,
        );

        LightSystemProgramCpi::new_cpi(LIGHT_CPI_SIGNER, proof)
            .with_light_account(loyalty_account)?
            .invoke(light_cpi_accounts)?;

        Ok(())
    }
}

#[derive(Accounts)]
pub struct LoyaltyAccounts<'info> {
    #[account(mut)]
    pub fee_payer: Signer<'info>,
    // remaining_accounts (not declared here) carries:
    //   [light_system_program_accounts..., packed_tree_accounts...]
    // built client-side with `PackedAccounts` — see agents/python_ts_client_agent.md
}

#[error_code]
pub enum LoyaltyError {
    #[msg("Tier must be 0 (none), 1 (standard), or 2 (vip)")]
    InvalidTier,
}
```

**Why `new_init` vs `new_mut` matters:** `new_init` proves a NEW address doesn't yet
exist (address-tree proof); `new_mut` proves the EXISTING leaf hash you're about to
overwrite is the real current state (state-tree proof). Mixing these up is the most
common source of "valid-looking" compressed-account bugs — see `security_rules.md`.

## 4. Reading Compressed State From the Photon Indexer (off-chain)

```typescript
import { createRpc, bn } from "@lightprotocol/stateless.js";
import { PublicKey } from "@solana/web3.js";

// Helius exposes the Solana RPC and the Photon Indexer through one URL.
const rpc = createRpc(
  `https://devnet.helius-rpc.com?api-key=${process.env.HELIUS_API_KEY}`,
  `https://devnet.helius-rpc.com?api-key=${process.env.HELIUS_API_KEY}`,
);

async function fetchLoyaltyTier(owner: PublicKey, programId: PublicKey) {
  // Derive the same deterministic address the on-chain program derives.
  const accounts = await rpc.getCompressedAccountsByOwner(programId);
  const match = accounts.items.find((acc) =>
    acc.data?.data && new PublicKey(acc.data.data.slice(0, 32)).equals(owner),
  );
  if (!match) return null;

  // A fresh proof MUST be fetched immediately before building the transaction
  // that consumes it — see security_rules.md, Rule 2.
  const proof = await rpc.getValidityProof([bn(match.hash)]);
  return { account: match, proof };
}
```

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
| `getCompressedAccount(address \| hash)` | Fetch a single compressed account by its persistent address or current leaf hash. |
| `getCompressedAccountsByOwner(owner)` | List all compressed accounts a program/owner controls. |
| `getCompressedTokenAccountsByOwner(owner, { mint? })` | List compressed SPL/Token-2022 balances. |
| `getValidityProof(hashes[], newAddressesWithTrees[])` | The single call that returns the ZK proof you pass into any instruction touching compressed state. **Always call this last, right before signing — see security_rules.md.** |
| `getIndexerHealth(slot)` | Sanity-check that the indexer has caught up to a given slot before trusting its results. |
| `getCompressionSignaturesForAccount(hash)` | Audit trail of every transaction that touched a given leaf — useful for the double-spend checks in `security_rules.md`. |
