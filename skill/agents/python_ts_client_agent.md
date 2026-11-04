# python_ts_client_agent.md

Off-chain client template: fetch compressed state + a validity proof from the Photon
Indexer, pack everything the Anchor program needs, resolve the Token-2022 transfer
hook's extra accounts, and submit one atomic transaction containing both the
`verify_loyalty_tier` and `transferChecked` instructions described in
`transfer_hooks.md`.

TypeScript is the primary, fully-supported client SDK for Light Protocol. Python
callers should use the JSON-RPC methods directly (shown at the end of this file).

## 1. Setup

```bash
npm install @lightprotocol/stateless.js@^0.23 @lightprotocol/compressed-token@^0.23 \
  @solana/web3.js@^1 @solana/spl-token@^0.4 @coral-xyz/anchor@0.31.1
```

`@coral-xyz/anchor` must match the program's `anchor-lang` version (0.31.1). The
IDL is produced by `anchor build` at `target/idl/zk_loyalty.json`.

```typescript
import {
  createRpc,
  Rpc,
  SystemAccountMetaConfig,
  getLightSystemAccountMetasLegacy,
  buildAndSignTx,
  sendAndConfirmTx,
  CompressedAccountWithMerkleContext,
  ValidityProofWithContext,
} from "@lightprotocol/stateless.js";
import {
  AccountMeta,
  ComputeBudgetProgram,
  Keypair,
  PublicKey,
  SystemProgram,
  TransactionInstruction,
} from "@solana/web3.js";
import {
  createTransferCheckedWithTransferHookInstruction,
  TOKEN_2022_PROGRAM_ID,
} from "@solana/spl-token";
import * as anchor from "@coral-xyz/anchor";
import idl from "../target/idl/zk_loyalty.json";

const HELIUS_API_KEY = process.env.HELIUS_API_KEY;
if (!HELIUS_API_KEY) throw new Error("Set HELIUS_API_KEY (see .env.example).");
const CLUSTER = process.env.SOLANA_CLUSTER === "mainnet-beta" ? "mainnet" : "devnet";
const HELIUS_RPC = `https://${CLUSTER}.helius-rpc.com?api-key=${HELIUS_API_KEY}`;

// One URL serves standard Solana RPC *and* the Photon indexer. `Rpc` extends
// web3.js `Connection`, so it can be used anywhere a Connection is expected.
const rpc: Rpc = createRpc(HELIUS_RPC, HELIUS_RPC);

// Instruction building only — no wallet needed on the provider.
const program = new anchor.Program(idl as anchor.Idl, { connection: rpc });
const programId = program.programId;
```

## 2. Step A — Fetch the Compressed Account + a Fresh Validity Proof

Compressed account `data.data` is the plain borsh encoding of the struct. The 8-byte
`LightDiscriminator` is stored separately in `data.discriminator`, so this is **not**
an Anchor account and must not be decoded with an Anchor coder.

```typescript
// Layout: owner (32) | tier (1) | points (u64 LE) | last_updated_slot (u64 LE)
const LOYALTY_TIER_LEN = 32 + 1 + 8 + 8;

interface LoyaltyTier {
  owner: PublicKey;
  tier: number;
  points: anchor.BN;
  lastUpdatedSlot: anchor.BN;
}

function decodeLoyaltyTier(data: Buffer): LoyaltyTier {
  if (data.length !== LOYALTY_TIER_LEN) {
    throw new Error(`Unexpected LoyaltyTier length ${data.length}`);
  }
  return {
    owner: new PublicKey(data.subarray(0, 32)),
    tier: data[32],
    points: new anchor.BN(data.subarray(33, 41), "le"),
    lastUpdatedSlot: new anchor.BN(data.subarray(41, 49), "le"),
  };
}

async function fetchLoyaltyProof(owner: PublicKey): Promise<{
  account: CompressedAccountWithMerkleContext;
  current: LoyaltyTier;
  proof: ValidityProofWithContext;
}> {
  let cursor: string | undefined;
  do {
    const page = await rpc.getCompressedAccountsByOwner(programId, { cursor });
    for (const account of page.items) {
      const raw = account.data?.data;
      if (!raw || raw.length !== LOYALTY_TIER_LEN) continue;
      const current = decodeLoyaltyTier(Buffer.from(raw));
      if (!current.owner.equals(owner)) continue;

      // CRITICAL: fetch this immediately before building the transaction. Do not
      // cache or reuse across retries — see security_rules.md, Rule 2.
      const proof = await rpc.getValidityProofV0(
        [{ hash: account.hash, tree: account.treeInfo.tree, queue: account.treeInfo.queue }],
        [],
      );
      return { account, current, proof };
    }
    cursor = page.cursor ?? undefined;
  } while (cursor);

  throw new Error("No compressed LoyaltyTier found for this owner.");
}
```

`current` must be passed to the program **unchanged**, including
`lastUpdatedSlot`, because the program re-hashes it to rebuild the input leaf.
Changing any field, or zeroing one, makes the proof fail.

## 3. Step B — Pack Accounts for the `verify_loyalty_tier` Instruction

The program uses Light's V1 CPI (`light_sdk::cpi::v1::CpiAccounts`), so the remaining
accounts are the **V1** system accounts followed by the tree accounts. stateless.js
≥ 0.23 defaults to V2, so `PackedAccounts.addSystemAccounts` would build the wrong
layout here. Use `getLightSystemAccountMetasLegacy` explicitly. Tree indices in
`CompressedAccountMeta` are relative to the first account **after** the system
accounts.

```typescript
async function buildVerifyInstruction(
  payer: PublicKey,
  owner: PublicKey,
  mint: PublicKey,
  account: CompressedAccountWithMerkleContext,
  current: LoyaltyTier,
  proof: ValidityProofWithContext,
): Promise<TransactionInstruction> {
  const systemAccounts = getLightSystemAccountMetasLegacy(SystemAccountMetaConfig.new(programId));
  const treeAccounts: AccountMeta[] = [
    { pubkey: account.treeInfo.tree, isSigner: false, isWritable: true },  // index 0
    { pubkey: account.treeInfo.queue, isSigner: false, isWritable: true }, // index 1
  ];

  if (!account.address) throw new Error("LoyaltyTier accounts always have an address.");

  const accountMeta = {
    treeInfo: {
      rootIndex: proof.rootIndices[0],       // from the proof response — never hand-written
      proveByIndex: proof.proveByIndices[0],
      merkleTreePubkeyIndex: 0,
      queuePubkeyIndex: 1,
      leafIndex: account.leafIndex,
    },
    address: account.address,
    outputStateTreeIndex: 0, // V1: the re-emitted leaf goes back into the same state tree
  };

  const [attestation] = PublicKey.findProgramAddressSync(
    [Buffer.from("loyalty-attestation"), owner.toBuffer(), mint.toBuffer()],
    programId,
  );

  return program.methods
    .verifyLoyaltyTier({ 0: proof.compressedProof }, accountMeta, current)
    .accountsStrict({
      feePayer: payer,
      mint,
      attestation,
      owner,
      systemProgram: SystemProgram.programId,
    })
    .remainingAccounts([...systemAccounts, ...treeAccounts])
    .instruction();
}
```

## 4. Step C — Build the Gated Transfer Instruction

`createTransferCheckedWithTransferHookInstruction` reads the mint's on-chain
`ExtraAccountMetaList` and derives every extra account it declares, including the
attestation PDA from `transfer_hooks.md`. Seed-based PDAs are derived locally, so
it's fine that the attestation doesn't exist yet when the instruction is built.

```typescript
async function buildTransferInstruction(
  source: PublicKey,
  mint: PublicKey,
  destination: PublicKey,
  owner: PublicKey,
  amount: bigint,
  decimals: number,
): Promise<TransactionInstruction> {
  return createTransferCheckedWithTransferHookInstruction(
    rpc,
    source,
    mint,
    destination,
    owner,
    amount,
    decimals,
    [],
    "confirmed",
    TOKEN_2022_PROGRAM_ID,
  );
}
```

## 5. Step D — Assemble, Sign, Submit (One Atomic Transaction)

```typescript
export async function sendGatedTransfer(
  payer: Keypair,
  owner: Keypair,
  source: PublicKey,
  mint: PublicKey,
  destination: PublicKey,
  amount: bigint,
  decimals: number,
): Promise<string> {
  const { account, current, proof } = await fetchLoyaltyProof(owner.publicKey);

  const verifyIx = await buildVerifyInstruction(
    payer.publicKey,
    owner.publicKey,
    mint,
    account,
    current,
    proof,
  );
  const transferIx = await buildTransferInstruction(
    source,
    mint,
    destination,
    owner.publicKey,
    amount,
    decimals,
  );

  const computeIx = ComputeBudgetProgram.setComputeUnitLimit({ units: 400_000 });

  // Order matters: verification MUST land before the transfer in the same tx.
  // `owner` signs both `verify_loyalty_tier` (attestation binding) and the transfer.
  const { blockhash } = await rpc.getLatestBlockhash();
  const tx = buildAndSignTx([computeIx, verifyIx, transferIx], payer, blockhash, [owner]);

  const signature = await sendAndConfirmTx(rpc, tx);
  console.log("Gated transfer confirmed:", signature);
  return signature;
}
```

On failure, **restart from `fetchLoyaltyProof`**. Never resend the same signed
transaction with a new blockhash. The proof (and, after a successful verify, the
leaf itself) is stale.

## 6. Python (or any non-JS client): Raw JSON-RPC Equivalent

Light Protocol does not ship a first-class Python SDK. Use the Photon JSON-RPC
methods directly over HTTPS (e.g. with `requests` or `httpx`). Then either hand the
resulting proof + account bytes to a thin TypeScript or Rust signer, or construct
the transaction with `solders`/`solana-py` directly, following the same account
layout as §3.

```python
import os

import requests

CLUSTER = "mainnet" if os.environ.get("SOLANA_CLUSTER") == "mainnet-beta" else "devnet"
HELIUS_RPC = f"https://{CLUSTER}.helius-rpc.com?api-key={os.environ['HELIUS_API_KEY']}"


def _photon(method: str, params: dict) -> dict:
    resp = requests.post(
        HELIUS_RPC,
        json={"jsonrpc": "2.0", "id": "zk-extensions-skill", "method": method, "params": params},
        timeout=30,
    )
    resp.raise_for_status()
    body = resp.json()
    # JSON-RPC errors come back as HTTP 200 with an "error" member.
    if "error" in body:
        raise RuntimeError(f"{method} failed: {body['error']}")
    return body["result"]["value"]


def get_validity_proof(hashes: list[str]) -> dict:
    return _photon("getValidityProof", {"hashes": hashes, "newAddressesWithTrees": []})


def get_compressed_account(hash_: str) -> dict | None:
    return _photon("getCompressedAccount", {"hash": hash_})
```

Treat the returned `compressedProof` (`a`, `b`, `c`, a compressed Groth16 proof)
and `rootIndices` exactly as the TypeScript path does: fetch last, never cache, never
reuse across transaction attempts.
