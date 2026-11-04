# transfer_hooks.md

Reference template for a Token-2022 **Transfer Hook** program, plus the production
pattern for gating that hook on **compressed** state (e.g. a compressed loyalty tier)
without violating the hook's account-resolution constraints.

## 1. Dependencies

```toml
[dependencies]
anchor-lang = { version = "0.31.1", features = ["init-if-needed"] }
anchor-spl = { version = "0.31.1", features = ["token_2022", "token_2022_extensions"] }
light-sdk = { version = "0.16.0", features = ["anchor"] }
spl-discriminator = "0.4"
spl-tlv-account-resolution = "0.9"
spl-transfer-hook-interface = "0.9"

[features]
idl-build = ["anchor-lang/idl-build", "anchor-spl/idl-build", "light-sdk/idl-build"]
```

The SPL interface crates **must** be the versions `anchor-spl` itself resolves.
`anchor-spl` 0.31.1 → `spl-token-2022` 6 → `spl-transfer-hook-interface` 0.9 /
`spl-tlv-account-resolution` 0.9. Pulling in 0.10 gives you a second copy of the
Solana types and confusing "expected `AccountInfo`, found `AccountInfo`" errors. Check
with `cargo tree -i spl-transfer-hook-interface`.

## 2. Why a Plain Transfer Hook Can't Reach Compressed State Directly

Token-2022 invokes your hook's `execute` instruction with a **fixed, interface-defined**
account list: `source`, `mint`, `destination`, `owner/authority`, the
`ExtraAccountMetaList` PDA, then whatever extra accounts you declared in that list,
resolved **by seeds, to pubkeys only**. There is no slot in this flow for:

- an arbitrary 128-byte ZK validity proof (the instruction data is fixed to `amount`),
- a live RPC round-trip to the Photon Indexer, or
- the Light System Program's V1 system accounts and tree accounts. A compressed-state
  CPI needs these, and the hook can't make Token-2022 forward them in a sound way.

So the hook cannot itself call `LightSystemProgramCpi` against fresh compressed state
mid-transfer. The safe pattern is to **split verification from enforcement**:

1. A **separate instruction** (`verify_loyalty_tier`, in the same program) runs
   *earlier in the same transaction*. It takes the validity proof, verifies the
   compressed `LoyaltyTier` account against the current state root, and writes a
   short-lived **attestation PDA** owned by this program. The attestation is
   seeded by `(owner, mint)` and requires `owner`'s signature.
2. The **transfer hook's `execute`** instruction is given that attestation PDA as one
   of its `ExtraAccountMetaList` entries. It checks that it was really invoked by
   Token-2022 mid-transfer, and that the attestation is fresh, matches the
   transferring owner, and meets the tier requirement. Then it **marks the
   attestation consumed** so it can't be replayed for a second transfer.

Because both instructions are in the same atomic transaction, there's no window for
the attestation to be reused or for the compressed state to change between steps 1
and 2. If either step fails, both roll back.

## 3. Wiring It Into the Program

The hook code lives in its own module, `programs/zk_loyalty/src/hook.rs`, next to the
`lib.rs` from `zk_compression.md`. Anchor only recognises instructions declared inside
the `#[program]` module, so `lib.rs` gets `pub mod hook;` plus three thin entrypoints:

```rust
// lib.rs — add next to the other top-level items:
pub mod hook;
pub use hook::*;
use spl_discriminator::SplDiscriminate;
use spl_transfer_hook_interface::instruction::ExecuteInstruction;

// lib.rs — add INSIDE `#[program] pub mod zk_loyalty { ... }`:
    pub fn verify_loyalty_tier<'info>(
        ctx: Context<'_, '_, '_, 'info, VerifyLoyalty<'info>>,
        proof: ValidityProof,
        account_meta: CompressedAccountMeta,
        current: LoyaltyTier,
    ) -> Result<()> {
        hook::verify_loyalty_tier_handler(ctx, proof, account_meta, current)
    }

    pub fn initialize_extra_account_meta_list(
        ctx: Context<InitializeExtraAccountMetaList>,
    ) -> Result<()> {
        hook::initialize_extra_account_meta_list_handler(ctx)
    }

    // Token-2022 calls this with the SPL interface discriminator
    // (`hash("spl-transfer-hook-interface:execute")[..8]`), NOT Anchor's default
    // `global:` one. Without this attribute the hook silently never matches.
    // (`#[interface(...)]` is deprecated since Anchor 0.31.1 and needs an extra
    // feature flag — use the discriminator override instead.)
    #[instruction(discriminator = ExecuteInstruction::SPL_DISCRIMINATOR_SLICE)]
    pub fn execute_transfer(ctx: Context<TransferHook>, amount: u64) -> Result<()> {
        hook::execute_transfer_handler(ctx, amount)
    }
```

## 4. The Attestation PDA

`hook.rs`:

```rust
use anchor_lang::prelude::*;
use anchor_spl::{
    token_2022::spl_token_2022::{
        extension::{transfer_hook::TransferHookAccount, BaseStateWithExtensions, StateWithExtensions},
        state::Account as Token2022Account,
    },
    token_interface::{Mint, TokenAccount},
};
use light_sdk::{
    account::LightAccount,
    cpi::{v1::{CpiAccounts, LightSystemProgramCpi}, InvokeLightSystemProgram, LightCpiInstruction},
    instruction::{account_meta::CompressedAccountMeta, ValidityProof},
};
use spl_tlv_account_resolution::{account::ExtraAccountMeta, seeds::Seed, state::ExtraAccountMetaList};
use spl_transfer_hook_interface::instruction::{ExecuteInstruction, TransferHookInstruction};

use crate::LoyaltyTier;

#[account]
#[derive(InitSpace)]
pub struct LoyaltyAttestation {
    pub owner: Pubkey,
    pub mint: Pubkey,
    pub tier: u8,
    pub verified_at_slot: u64,
    pub consumed: bool,
}

impl LoyaltyAttestation {
    pub const SEED: &'static [u8] = b"loyalty-attestation";
    // Must be consumed within ~1-2 slots of verification (security_rules.md, Rule 2).
    // In the intended single-transaction flow the difference is 0.
    pub const MAX_VALID_SLOTS: u64 = 2;
}
```

## 5. Step 1 — Verification Instruction (writes the attestation)

```rust
pub fn verify_loyalty_tier_handler<'info>(
    ctx: Context<'_, '_, '_, 'info, VerifyLoyalty<'info>>,
    proof: ValidityProof,
    account_meta: CompressedAccountMeta,
    current: LoyaltyTier,
) -> Result<()> {
    // The tier we attest to must belong to the wallet that signed this instruction.
    require_keys_eq!(current.owner, ctx.accounts.owner.key(), HookError::AttestationMismatch);
    let tier = current.tier;

    // Verified against: the state-tree root at `account_meta.tree_info.root_index`,
    // from the same `getValidityProofV0` response as `proof`. The leaf hash commits
    // to this program as owner and to every field of `current`. If the client lies
    // about `tier` (or any other field), the hash doesn't match and the CPI fails.
    // That is what makes `tier` trustworthy.
    let loyalty_account =
        LightAccount::<LoyaltyTier>::new_mut(&crate::ID, &account_meta, current)?;

    let light_cpi_accounts = CpiAccounts::new(
        ctx.accounts.fee_payer.as_ref(),
        ctx.remaining_accounts,
        crate::LIGHT_CPI_SIGNER,
    );

    // No fields are modified, so the account is re-emitted with identical data.
    // Under V1 this is still a write: the input leaf is nullified and a new leaf is
    // appended. Not replayable: a nullified leaf can never be proven again, so the
    // client must fetch a fresh proof for every verification.
    // (Under Light V2 you can use `LightAccount::new_read_only` +
    // `with_read_only_accounts` to prove inclusion without rewriting the leaf.)
    LightSystemProgramCpi::new_cpi(crate::LIGHT_CPI_SIGNER, proof)
        .with_light_account(loyalty_account)?
        .invoke(light_cpi_accounts)?;

    let attestation = &mut ctx.accounts.attestation;
    attestation.owner = ctx.accounts.owner.key();
    attestation.mint = ctx.accounts.mint.key();
    attestation.tier = tier;
    attestation.verified_at_slot = Clock::get()?.slot;
    attestation.consumed = false;

    Ok(())
}

#[derive(Accounts)]
pub struct VerifyLoyalty<'info> {
    #[account(mut)]
    pub fee_payer: Signer<'info>,
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(
        init_if_needed,
        payer = fee_payer,
        space = 8 + LoyaltyAttestation::INIT_SPACE,
        seeds = [LoyaltyAttestation::SEED, owner.key().as_ref(), mint.key().as_ref()],
        bump,
    )]
    pub attestation: Account<'info, LoyaltyAttestation>,
    /// Must sign: nobody can create or refresh an attestation for someone else's
    /// wallet (security_rules.md, Rule 3).
    pub owner: Signer<'info>,
    pub system_program: Program<'info, System>,
    // remaining_accounts: [light system accounts (V1)..., state tree, queue]
}
```

`init_if_needed` is safe here only because **every** field is overwritten on each
call, and the PDA is bound to a signing `owner`. Don't copy this pattern for
accounts where a stale field could survive re-initialisation.

## 6. Step 2 — The Transfer Hook Itself

```rust
#[derive(Accounts)]
pub struct InitializeExtraAccountMetaList<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    /// CHECK: created and sized by `ExtraAccountMetaList::init` below.
    #[account(mut, seeds = [b"extra-account-metas", mint.key().as_ref()], bump)]
    pub extra_account_meta_list: UncheckedAccount<'info>,
    pub mint: InterfaceAccount<'info, Mint>,
    pub system_program: Program<'info, System>,
}

pub fn initialize_extra_account_meta_list_handler(
    ctx: Context<InitializeExtraAccountMetaList>,
) -> Result<()> {
    // The hook only needs ONE extra account: the attestation PDA, resolved
    // from seeds the same way the verification instruction derived it.
    // `Seed::AccountKey { index: 3 }` pulls the key of the transfer's
    // owner/authority account, so the resolver can't be tricked into
    // checking someone else's attestation.
    let extra_metas = vec![ExtraAccountMeta::new_with_seeds(
        &[
            Seed::Literal { bytes: LoyaltyAttestation::SEED.to_vec() },
            Seed::AccountKey { index: 3 }, // owner/authority
            Seed::AccountKey { index: 1 }, // mint
        ],
        false, // is_signer
        true,  // is_writable — we need to mark it consumed
    )?];

    let account_size = ExtraAccountMetaList::size_of(extra_metas.len())?;
    let lamports = Rent::get()?.minimum_balance(account_size);
    let mint_key = ctx.accounts.mint.key();
    let signer_seeds: &[&[&[u8]]] = &[&[
        b"extra-account-metas",
        mint_key.as_ref(),
        &[ctx.bumps.extra_account_meta_list],
    ]];

    anchor_lang::system_program::create_account(
        CpiContext::new_with_signer(
            ctx.accounts.system_program.to_account_info(),
            anchor_lang::system_program::CreateAccount {
                from: ctx.accounts.payer.to_account_info(),
                to: ctx.accounts.extra_account_meta_list.to_account_info(),
            },
            signer_seeds,
        ),
        lamports,
        account_size as u64,
        &crate::ID,
    )?;

    let mut data = ctx.accounts.extra_account_meta_list.try_borrow_mut_data()?;
    ExtraAccountMetaList::init::<ExecuteInstruction>(&mut data, &extra_metas)?;

    Ok(())
}

#[derive(Accounts)]
pub struct TransferHook<'info> {
    pub source_token: InterfaceAccount<'info, TokenAccount>,
    pub mint: InterfaceAccount<'info, Mint>,
    pub destination_token: InterfaceAccount<'info, TokenAccount>,
    /// CHECK: owner/authority of the transfer (index 3), matching the seed
    /// resolution above. If a delegate signs the transfer, this is the delegate,
    /// and the delegate needs its own attestation.
    pub owner: UncheckedAccount<'info>,
    /// CHECK: seeds checked here, contents checked by `check_account_infos` below.
    #[account(seeds = [b"extra-account-metas", mint.key().as_ref()], bump)]
    pub extra_account_meta_list: UncheckedAccount<'info>,
    #[account(
        mut,
        seeds = [LoyaltyAttestation::SEED, owner.key().as_ref(), mint.key().as_ref()],
        bump,
    )]
    pub attestation: Account<'info, LoyaltyAttestation>,
}

pub fn execute_transfer_handler(ctx: Context<TransferHook>, amount: u64) -> Result<()> {
    // Step A — refuse direct calls. Token-2022 sets the `transferring` flag on
    // both token accounts only for the duration of a real transfer. Without
    // this check anyone could call `execute` directly and burn a victim's
    // attestation (security_rules.md, Rule 4).
    assert_is_transferring(&ctx.accounts.source_token.to_account_info())?;
    assert_is_transferring(&ctx.accounts.destination_token.to_account_info())?;

    // Step B — confirm Token-2022 actually resolved every extra account this
    // hook requires. Never skip this: see security_rules.md, Rule 4.
    {
        let data = ctx.accounts.extra_account_meta_list.try_borrow_data()?;
        ExtraAccountMetaList::check_account_infos::<ExecuteInstruction>(
            &ctx.accounts.to_account_infos(),
            &TransferHookInstruction::Execute { amount }.pack(),
            ctx.program_id,
            &data,
        )?;
    }

    // Step C — enforce the attestation. Every check fails closed.
    let attestation = &mut ctx.accounts.attestation;
    require_keys_eq!(attestation.owner, ctx.accounts.owner.key(), HookError::AttestationMismatch);
    require_keys_eq!(attestation.mint, ctx.accounts.mint.key(), HookError::AttestationMismatch);
    require!(!attestation.consumed, HookError::AttestationAlreadyConsumed);

    let current_slot = Clock::get()?.slot;
    require!(
        current_slot.saturating_sub(attestation.verified_at_slot)
            <= LoyaltyAttestation::MAX_VALID_SLOTS,
        HookError::AttestationStale
    );

    require!(attestation.tier >= 2, HookError::InsufficientTier); // VIP-only example

    // Consume it — this transaction's transfer is the only thing this
    // attestation will ever authorize.
    attestation.consumed = true;

    Ok(())
}

fn assert_is_transferring(token_account: &AccountInfo) -> Result<()> {
    let data = token_account.try_borrow_data()?;
    let account = StateWithExtensions::<Token2022Account>::unpack(&data)?;
    let extension = account.get_extension::<TransferHookAccount>()?;
    require!(bool::from(extension.transferring), HookError::NotTransferring);
    Ok(())
}

// Offset so these codes don't collide with LoyaltyError (which starts at 6000).
#[error_code(offset = 6100)]
pub enum HookError {
    #[msg("Attestation does not match the transferring owner or mint")]
    AttestationMismatch,
    #[msg("Attestation already consumed by a prior transfer")]
    AttestationAlreadyConsumed,
    #[msg("Attestation is stale — re-verify against current compressed state")]
    AttestationStale,
    #[msg("Wallet's compressed loyalty tier does not meet the required threshold")]
    InsufficientTier,
    #[msg("Hook was not invoked by Token-2022 during a transfer")]
    NotTransferring,
}
```

Client-side, the transaction must contain, **in order**: `verify_loyalty_tier` →
the Token-2022 `transferChecked` instruction (which triggers `execute_transfer` via
CPI). See `agents/python_ts_client_agent.md` for the full build sequence, including
how the attestation PDA is resolved into the transfer instruction's extra accounts.

The mint also needs the hook set up once: create it with the `TransferHook`
extension pointing at this program, then call `initialize_extra_account_meta_list`.
Until the meta list exists, every transfer of the mint fails.

## 7. Confidential Transfers — Note

If the mint also has the `ConfidentialTransferMint` extension enabled, the cleartext
transfer amount is not available to the hook for confidential transfers. Never write
hook logic that branches on `amount` for a mint where confidentiality is enabled,
because that value will not be reliable. Tier-gating logic above doesn't depend on
the amount, so it composes with confidential transfers. If you genuinely need
amount-based limits on a confidential mint, a transfer hook is the wrong place to
enforce them. Say so explicitly rather than generating hook code that pretends to
check the amount.
