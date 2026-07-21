`transfer_hooks.md`.
## 1. Setup
TypeScript is the primary, fully-supported client SDK for Light Protocol; Python
callers should use the JSON-RPC methods directly (shown at the end of this file).

## 1. Setup

```bash
npm install @lightprotocol/stateless.js @lightprotocol/compressed-token \
  @solana/web3.js @solana/spl-token @coral-xyz/anchor
```

```typescript
import {
  createRpc,
  bn,
  Rpc,
  PackedAccounts,
  SystemAccountMetaConfig,
  buildAndSignTx,
  sendAndConfirmTx,
} from "@lightprotocol/stateless.js";
import {
```
  Keypair,
  PublicKey,
  TransactionInstruction,
  ComputeBudgetProgram,
} from "@solana/web3.js";
import {
  createTransferCheckedWithTransferHookInstruction,
  TOKEN_2022_PROGRAM_ID,
} from "@solana/spl-token";
import * as anchor from "@coral-xyz/anchor";
import idl from "../target/idl/zk_loyalty.json";

const HELIUS_RPC = `https://devnet.helius-rpc.com?api-key=${process.env.HELIUS_API_KEY}`;
const rpc: Rpc = createRpc(HELIUS_RPC, HELIUS_RPC);
const connection = new Connection(HELIUS_RPC, "confirmed");

const programId = new PublicKey(idl.address);
const coder = new anchor.BorshInstructionCoder(idl as anchor.Idl);
```

## 2. Step A — Fetch the Compressed Account + a Fresh Validity Proof

```typescript
async function fetchLoyaltyProof(owner: PublicKey) {
  // Find the owner's compressed LoyaltyTier account.
  const { items } = await rpc.getCompressedAccountsByOwner(programId);
  const account = items.find((acc) => {
    const decoded = coder.decode(Buffer.from(acc.data?.data ?? []), "base64");
    return decoded?.owner?.equals?.(owner) ?? false;
  });
  if (!account) throw new Error("No compressed LoyaltyTier found for this owner.");

  // CRITICAL: fetch this immediately before building the transaction. Do not
  // cache or reuse across retries — see security_rules.md, Rule 2.
  const proof = await rpc.getValidityProof([bn(account.hash)]);

  return { account, proof };
}
```

## 3. Step B — Pack Accounts for the `verify_loyalty_tier` Instruction

```typescript
async function buildVerifyInstruction(
  payer: PublicKey,
  owner: PublicKey,
  account: Awaited<ReturnType<typeof fetchLoyaltyProof>>["account"],
  proof: Awaited<ReturnType<typeof fetchLoyaltyProof>>["proof"],
  mint: PublicKey,
): Promise<TransactionInstruction> {
  const packed = new PackedAccounts();
  const systemConfig = SystemAccountMetaConfig.new(programId);
  packed.addSystemAccounts(systemConfig);

  const stateTreeIndex = packed.insertOrGet(account.treeInfo.tree);
  const queueIndex = packed.insertOrGet(account.treeInfo.queue);

  const [accountMetas, _readOnly] = packed.toAccountMetas();

  const [attestationPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("loyalty-attestation"), owner.toBuffer(), mint.toBuffer()],
    programId,
  );

  const decoded = coder.decode(Buffer.from(account.data!.data), "base64")!;

  const data = coder.encode("verifyLoyaltyTier", {
    proof: proof.compressedProof,
    accountMeta: {
      treeInfo: {
        rootIndex: proof.rootIndices[0],
        merkleTreePubkeyIndex: stateTreeIndex,
        queuePubkeyIndex: queueIndex,
        leafIndex: account.leafIndex,
        proveByIndex: false,
      },
      address: account.address ?? null,
      outputStateTreeIndex: stateTreeIndex,
    },
    owner,
    tier: decoded.tier,
    points: decoded.points,
  });

  return new TransactionInstruction({
    programId,
    keys: [
      { pubkey: payer, isSigner: true, isWritable: true },
      { pubkey: mint, isSigner: false, isWritable: false },
      { pubkey: attestationPda, isSigner: false, isWritable: true },
      { pubkey: owner, isSigner: false, isWritable: false },
      ...accountMetas,
    ],
    data,
  });
}
```

## 4. Step C — Build the Gated Transfer Instruction

`createTransferCheckedWithTransferHookInstruction` simulates the transfer to resolve
every `ExtraAccountMetaList` entry (including the attestation PDA derived in
`transfer_hooks.md`) automatically — no manual seed resolution required client-side.

```typescript
async function buildTransferInstruction(
  source: PublicKey,
  mint: PublicKey,
  destination: PublicKey,
  owner: PublicKey,
  amount: bigint,
  decimals: number,
) {
  return createTransferCheckedWithTransferHookInstruction(
    connection,
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
async function sendGatedTransfer(
  payer: Keypair,
  owner: Keypair,
  source: PublicKey,
  mint: PublicKey,
  destination: PublicKey,
  amount: bigint,
  decimals: number,
) {
  const { account, proof } = await fetchLoyaltyProof(owner.publicKey);

  const verifyIx = await buildVerifyInstruction(
    payer.publicKey,
    owner.publicKey,
    account,
    proof,
    mint,
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
  const tx = buildAndSignTx(
    [computeIx, verifyIx, transferIx],
    payer,
    (await rpc.getLatestBlockhash()).blockhash,
    [owner],
  );

  const signature = await sendAndConfirmTx(rpc, tx);
  console.log("Gated transfer confirmed:", signature);
  return signature;
}
```

## 6. Python (or any non-JS client): Raw JSON-RPC Equivalent

Light Protocol does not ship a first-class Python SDK; use the Photon JSON-RPC
methods directly over HTTPS (e.g. with `requests` or `httpx`), then hand the
resulting proof + account bytes to a thin TypeScript or Rust signer, or construct
the transaction with `solders`/`solana-py` directly.

```python
import requests

HELIUS_RPC = f"https://devnet.helius-rpc.com?api-key={HELIUS_API_KEY}"

def get_validity_proof(hashes: list[str]) -> dict:
    resp = requests.post(HELIUS_RPC, json={
        "jsonrpc": "2.0",
        "id": "zk-extensions-skill",
        "method": "getValidityProof",
        "params": {"hashes": hashes},
    })
    resp.raise_for_status()
    return resp.json()["result"]["value"]

def get_compressed_account(hash_: str) -> dict:
    resp = requests.post(HELIUS_RPC, json={
        "jsonrpc": "2.0",
        "id": "zk-extensions-skill",
        "method": "getCompressedAccount",
        "params": {"hash": hash_},
    })
    resp.raise_for_status()
    return resp.json()["result"]["value"]
```

Treat the returned `compressedProof` (`a`, `b`, `c` — a Groth16-style proof triple)
and `rootIndices` exactly as the TypeScript path does: fetch last, never cache, never
reuse across transaction attempts.
