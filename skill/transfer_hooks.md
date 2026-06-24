# transfer_hooks.md

Reference template for a Token-2022 **Transfer Hook** program, plus the production
pattern for gating that hook on **compressed** state (e.g. a compressed loyalty tier)
without violating the hook's account-resolution constraints.

## 1. Dependencies

```toml
[dependencies]
anchor-lang = "0.31.1"
anchor-spl = { version = "0.31.1", features = ["token_2022", "token_2022_extensions"] }
spl-transfer-hook-interface = "0.10.0"
spl-tlv-account-resolution = "0.10.0"
light-sdk = "0.16.0"

[features]
idl-build = ["anchor-lang/idl-build", "anchor-spl/idl-build"]
```

## 2. Why a Plain Transfer Hook Can't Reach Compressed State Directly

Token-2022 invokes your hook's `execute` instruction with a **fixed, interface-defined**
account list: `source`, `mint`, `destination`, `owner/authority`, the
`ExtraAccountMetaList` PDA, then whatever extra accounts you declared in that list,
resolved **by seeds, to pubkeys only**. There is no slot in this flow for:

- an arbitrary 128-byte ZK validity proof,
- a live RPC round-trip to the Photon Indexer, or
- more than one validity-proof verification per instruction (the Light System Program
  enforces this — see `security_rules.md`, Rule 1).

So the hook cannot itself call `LightSystemProgramCpi` against fresh compressed state
mid-transfer. The safe pattern is to **split verification from enforcement**:

1. A **separate instruction** (`verify_loyalty_tier`, same program or a companion
   program) runs *earlier in the same transaction*. It takes the validity proof,
   verifies the compressed `LoyaltyTier` account against the current state root, and
   writes a short-lived **attestation PDA** signed into existence by this program.
2. The **transfer hook's `execute`** instruction is given that attestation PDA as one
   of its `ExtraAccountMetaList` entries. It checks the attestation is fresh, matches
   the transferring owner, and meets the tier requirement — then **closes/zeroes it**
   so it can't be replayed for a second transfer.

Because both instructions are in the same atomic transaction, there's no window for
the attestation to be reused or for the compressed state to change between steps 1
and 2.

## 3. The Attestation PDA

```rust
use anchor_lang::prelude::*;

#[account]
pub struct LoyaltyAttestation {
    pub owner: Pubkey,
    pub mint: Pubkey,
    pub tier: u8,
    pub verified_at_slot: u64,
    pub consumed: bool,
}

impl LoyaltyAttestation {
    pub const SEED: &'static [u8] = b"loyalty-attestation";
    pub const MAX_VALID_SLOTS: u64 = 2; // must be consumed within ~1-2 slots of verification
}
```

## 4. Step 1 — Verification Instruction (writes the attestation)

```rust
use light_sdk::{
    account::LightAccount,
    cpi::CpiAccounts,
    instruction::ValidityProof,
    compressed_account::CompressedAccountMeta,
};

pub fn verify_loyalty_tier<'info>(
    ctx: Context<'_, '_, '_, 'info, VerifyLoyalty<'info>>,
    proof: ValidityProof,
    account_meta: CompressedAccountMeta,
    owner: Pubkey,
    tier: u8,
    points: u64,
) -> Result<()> {
    // Re-derive the LightAccount from the SAME proof+meta the client fetched
    // moments ago. If the leaf hash doesn't match the current state root,
    // the Light System Program CPI below fails — this is what makes the
    // "tier" value trustworthy.
    let loyalty_account = LightAccount::<'_, super::LoyaltyTier>::new_mut(
        &super::ID,
        &account_meta,
        super::LoyaltyTier { owner, tier, points, last_updated_slot: 0 },
    )?;

    let light_cpi_accounts = CpiAccounts::new(
        ctx.accounts.fee_payer.as_ref(),
        ctx.remaining_accounts,
        super::LIGHT_CPI_SIGNER,
    );

    // Read-only check: we invoke with `with_light_account` but do not mutate
    // tier/points, so the output hash equals the input hash. This still
    // requires the proof to be valid against the CURRENT root.
    light_sdk::cpi::LightSystemProgramCpi::new_cpi(super::LIGHT_CPI_SIGNER, proof)
        .with_light_account(loyalty_account)?
        .invoke(light_cpi_accounts)?;

    let attestation = &mut ctx.accounts.attestation;
    attestation.owner = owner;
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
    pub mint: InterfaceAccount<'info, anchor_spl::token_interface::Mint>,
    #[account(
        init_if_needed,
        payer = fee_payer,
        space = 8 + 32 + 32 + 1 + 8 + 1,
        seeds = [LoyaltyAttestation::SEED, owner.key().as_ref(), mint.key().as_ref()],
        bump,
    )]
    pub attestation: Account<'info, LoyaltyAttestation>,
    /// CHECK: validated by seed derivation above, not read directly here.
    pub owner: UncheckedAccount<'info>,
}
```

## 5. Step 2 — The Transfer Hook Itself

```rust
use anchor_spl::token_interface::{Mint, TokenAccount, TokenInterface};
use spl_tlv_account_resolution::{account::ExtraAccountMeta, seeds::Seed, state::ExtraAccountMetaList};
use spl_transfer_hook_interface::instruction::ExecuteInstruction;

#[derive(Accounts)]
pub struct InitializeExtraAccountMetaList<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(
        mut,
        seeds = [b"extra-account-metas", mint.key().as_ref()],
        bump,
    )]
    /// CHECK: created and sized by `ExtraAccountMetaList::init` below.
    pub extra_account_meta_list: UncheckedAccount<'info>,
    pub mint: InterfaceAccount<'info, Mint>,
    pub system_program: Program<'info, System>,
}

pub fn initialize_extra_account_meta_list(
    ctx: Context<InitializeExtraAccountMetaList>,
) -> Result<()> {
    // The hook only needs ONE extra account: the attestation PDA, resolved
    // from seeds the same way the verification instruction derived it.
    // `Seed::AccountKey` pulls the owner from account index 3 (the transfer's
    // `owner`/authority account) so the resolver can't be tricked into
    // checking someone else's attestation.
    let extra_metas = vec![
        ExtraAccountMeta::new_with_seeds(
            &[
                Seed::Literal { bytes: LoyaltyAttestation::SEED.to_vec() },
                Seed::AccountKey { index: 3 }, // owner/authority
                Seed::AccountKey { index: 1 }, // mint
            ],
            false, // is_signer
            true,  // is_writable — we need to mark it consumed
        )?,
    ];

    let account_size = ExtraAccountMetaList::size_of(extra_metas.len())?;
    let lamports = Rent::get()?.minimum_balance(account_size);

    anchor_lang::system_program::create_account(
        CpiContext::new(
            ctx.accounts.system_program.to_account_info(),
            anchor_lang::system_program::CreateAccount {
                from: ctx.accounts.payer.to_account_info(),
                to: ctx.accounts.extra_account_meta_list.to_account_info(),
            },
        )
        .with_signer(&[&[
            b"extra-account-metas",
            ctx.accounts.mint.key().as_ref(),
            &[ctx.bumps.extra_account_meta_list],
        ]]),
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
    /// CHECK: owner/authority of the transfer — index 3, matches the seed
    /// resolution above.
    pub owner: UncheckedAccount<'info>,
    /// CHECK: validated by `ExtraAccountMetaList::check_account_infos` below.
    pub extra_account_meta_list: UncheckedAccount<'info>,
    #[account(
        mut,
        seeds = [LoyaltyAttestation::SEED, owner.key().as_ref(), mint.key().as_ref()],
        bump,
    )]
    pub attestation: Account<'info, LoyaltyAttestation>,
}

#[interface(spl_transfer_hook_interface::execute)]
pub fn execute_transfer(ctx: Context<TransferHook>, _amount: u64) -> Result<()> {
    // Step A — confirm Token-2022 actually resolved every extra account this
    // hook requires. Never skip this: see security_rules.md, Rule 4.
    let data = ctx.accounts.extra_account_meta_list.try_borrow_data()?;
    ExtraAccountMetaList::check_account_infos::<ExecuteInstruction>(
        &ctx.accounts.to_account_infos(),
        &spl_transfer_hook_interface::instruction::TransferHookInstruction::Execute {
            amount: _amount,
        }
        .pack(),
        &ctx.program_id,
        &data,
    )?;

    let attestation = &mut ctx.accounts.attestation;

    require_keys_eq!(attestation.owner, ctx.accounts.owner.key(), HookError::AttestationMismatch);
    require_keys_eq!(attestation.mint, ctx.accounts.mint.key(), HookError::AttestationMismatch);
    require!(!attestation.consumed, HookError::AttestationAlreadyConsumed);

    let current_slot = Clock::get()?.slot;
    require!(
        current_slot.saturating_sub(attestation.verified_at_slot) <= LoyaltyAttestation::MAX_VALID_SLOTS,
        HookError::AttestationStale
    );

    require!(attestation.tier >= 2, HookError::InsufficientTier); // VIP-only example

    // Consume it — this transaction's transfer is the only thing this
    // attestation will ever authorize.
    attestation.consumed = true;

    Ok(())
}

#[error_code]
pub enum HookError {
    #[msg("Attestation does not match the transferring owner or mint")]
    AttestationMismatch,
    #[msg("Attestation already consumed by a prior transfer")]
    AttestationAlreadyConsumed,
    #[msg("Attestation is stale — re-verify against current compressed state")]
    AttestationStale,
    #[msg("Wallet's compressed loyalty tier does not meet the required threshold")]
    InsufficientTier,
}
```

Client-side, the transaction must contain, **in order**: `verify_loyalty_tier` →
the Token-2022 `transferChecked` instruction (which triggers `execute_transfer` via
CPI). See `agents/python_ts_client_agent.md` for the full build sequence, including
how to resolve the attestation PDA into the transfer instruction's extra accounts.

## 6. Confidential Transfers — Note

If the mint also has the `ConfidentialTransferMint` extension enabled, transfer
amounts in `execute_transfer` may be encrypted/zeroed at the interface level
depending on configuration. Tier-gating logic above does not depend on the amount, so
it composes safely with confidential transfers — but never write hook logic that
branches on the cleartext `amount` parameter for a mint where confidentiality is
enabled, since that value will not be reliable. Validate against `account_meta`-level
encrypted balance proofs instead if amount-based gating is required.
