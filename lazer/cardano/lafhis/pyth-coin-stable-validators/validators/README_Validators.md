# pyth-coin-stable — Cardano Dueling Dapp

A real-time asset price dueling game on Cardano. Two players each choose a cryptocurrency asset and bet ADA on which one will appreciate more in a fixed time window. The winner is determined on-chain using live prices from the Pyth oracle network.

---

## How it works

Player A creates a duel and deposits a bet. Player B joins and chooses a different asset. At the moment both players are connected, their assets' start prices are recorded from Pyth. After a deadline (e.g. 60 seconds), the backend resolves the duel: whichever asset had the higher percentage gain wins the pot. If the difference is under 1%, it's a draw and both players are refunded.

---

## Validators

### `nft_policy` — `validators/nft.ak`

A minting policy that controls the lifecycle of the authenticity NFT tied to each duel.

**Parameter**

| Name | Type | Description |
|---|---|---|
| `backend_pkh` | `VerificationKeyHash` | Only the backend can authorize minting, preventing spam duels. |

**Redeemer**

```
Mint { utxo_ref: OutputReference }
Burn
```

**`Mint` logic**

1. The `utxo_ref` in the redeemer must be consumed as an input in this transaction. This guarantees that `duel_id` is unique — a UTxO can only be spent once.
2. Exactly one token is minted under this policy, with `asset_name = duel_id`, where:
   ```
   duel_id = sha2_256(utxo_ref.transaction_id ++ from_int_big_endian(utxo_ref.output_index, 8))
   ```
3. The backend must sign the transaction.

**`Burn` logic**

All tokens burned under this policy must have quantity `-1`. Called in both `Resolve` and `Cancel`.

> **Compile this validator first.** Its hash is used as the `nft_policy_id` parameter in `bet`.

---

### `bet` — `validators/validators.ak`

The main spending validator. Controls the three state transitions of a duel.

**Parameters**

| Name | Type | Description |
|---|---|---|
| `backend_pkh` | `VerificationKeyHash` | Backend trusted to build and sign Join/Resolve transactions. |
| `nft_policy_id` | `PolicyId` | Hash of `nft_policy` (applied off-chain after compiling). |
| `pyth_id` | `PolicyId` | Pyth deployment policy ID on this network. |

**Datum — `DuelDatum`**

```
duel_id             ByteArray       sha2_256 of the consumed wallet UTxO
player_a            Player          pkh, feed_id, start_price
player_b            Option<Player>  None until Join
bet_amount_lovelace Int             Individual bet; pot = 2 ×
status              DuelStatus      Waiting | Active | Finished
deadline            Option<Int>     POSIX ms; set on Join
```

**Redeemer — `DuelRedeemer`**

```
Join    { player_pkh: VerificationKeyHash, feed_id: Int }
Resolve { timestamp: Int }
Cancel
```

---

#### Action: `Join`

Called when Player B joins an open duel.

**Preconditions checked**

| Check | Description |
|---|---|
| `status == Waiting` | Duel must be open. |
| `player_pkh != player_a.pkh` | Player B cannot be Player A. |
| `player_b == None` | No opponent yet. |
| `feed_id != player_a.feed_id` | Players must choose different assets. |
| `signed_by(backend_pkh)` | Backend must co-sign. |
| Pyth prices available | Both `feed_id`s must have a valid price update in the Pyth withdrawal. |
| Continuing output valid | The output UTxO must carry `2 × bet_amount`, `status = Active`, both `start_price`s set to the Pyth prices read from this transaction, a valid deadline, and the authenticity NFT. |

**Transaction shape**

```
Inputs:       script UTxO (Waiting) + Player B wallet UTxO
Ref inputs:   Pyth state UTxO
Withdrawals:  0 lovelace from Pyth withdraw script
              redeemer = [signed_update_feed_a, signed_update_feed_b]
Outputs:      script UTxO (Active), pot = 2 × bet_amount
Signers:      Player B + Backend
```

---

#### Action: `Resolve`

Called by the backend after the deadline to determine the winner.

**Preconditions checked**

| Check | Description |
|---|---|
| `status == Active` | Duel must be in progress. |
| `signed_by(backend_pkh)` | Backend must sign. |
| `timestamp >= deadline` | Cannot resolve before the deadline. |
| Pyth end prices available | Both feeds must have a current price update. |
| Payout correct | Funds must go to the correct address based on winner calculation. |

**Winner calculation**

```
change_a = (end_price_a - start_price_a) / start_price_a × 1_000_000
change_b = (end_price_b - start_price_b) / start_price_b × 1_000_000

if |change_a - change_b| < 10_000   → draw: both refunded
elif change_a > change_b            → Player A wins the pot
else                                → Player B wins the pot
```

The 10_000 threshold corresponds to a 1% difference in scaled units.

**Transaction shape**

```
Inputs:      script UTxO (Active)
Ref inputs:  Pyth state UTxO
Withdrawals: 0 lovelace from Pyth withdraw script
             redeemer = [signed_update_feed_a, signed_update_feed_b]
Outputs:     winner address (full pot) OR both addresses (draw)
Burn:        -1 NFT
Signers:     Backend
```

---

#### Action: `Cancel`

Called to abort a duel that never started (no Player B).

**Preconditions checked**

| Check | Description |
|---|---|
| `status == Waiting` | Only valid before a duel starts. |
| `player_b == None` | No opponent has joined. |
| Authorized | Player A or backend must sign. |
| Refund correct | Player A must receive at least `bet_amount_lovelace`. |
| NFT burned | `quantity_of(mint, nft_policy_id, duel_id) == -1`. |

**Transaction shape**

```
Inputs:  script UTxO (Waiting)
Outputs: Player A address (bet_amount refunded)
Burn:    -1 NFT
Signers: Player A or Backend
```

---

## NFT lifecycle

The authenticity NFT (`nft_policy_id`, `asset_name = duel_id`) travels with the script UTxO and proves its origin.

```
TX 1 Create   →  +1 NFT minted, lives in script UTxO
TX 2 Join     →  NFT passes to new script UTxO (continuing output)
TX 3 Resolve  →  -1 NFT burned, pot paid out
TX 3b Cancel  →  -1 NFT burned, bet refunded
```

---

## Off-chain: computing `duel_id`

The `duel_id` must be computed before building TX 1, using the wallet UTxO that Player A will consume as input.

```typescript
import { sha256 } from "@noble/hashes/sha256"
import { bytesToHex, hexToBytes } from "@noble/hashes/utils"

function deriveDuelId(txHash: string, outputIndex: number): string {
  const hashBytes = hexToBytes(txHash)                    // 32 bytes
  const indexBuf  = new ArrayBuffer(8)
  new DataView(indexBuf).setBigUint64(0, BigInt(outputIndex), false) // big-endian, 8 bytes
  const indexBytes = new Uint8Array(indexBuf)

  const combined = new Uint8Array(40)
  combined.set(hashBytes, 0)
  combined.set(indexBytes, 32)

  return bytesToHex(sha256(combined))
}
```

This matches `sha2_256(bytearray.concat(transaction_id, from_int_big_endian(output_index, 8)))` in the on-chain code.

---

## Build order

```bash
# 1. Add dependencies to aiken.toml
[[dependencies]]
name = "aiken-lang/stdlib"
version = "v3"
source = "github"

[[dependencies]]
name = "pyth-network/pyth-lazer-cardano"
version = "main"
source = "github"

# 2. Download and compile
aiken packages download
aiken build

# 3. Find nft_policy hash in plutus.json → use as nft_policy_id when applying
#    parameters to bet.spend off-chain via applyParamsToScript
```

**Parameter application order (off-chain)**

```
applyParamsToScript(nft_policy.compiledCode, [backend_pkh])
    → hash → nft_policy_id

applyParamsToScript(bet.compiledCode, [backend_pkh, nft_policy_id, pyth_id])
    → final bet script ready to deploy
```

---

## Pyth integration

Prices are verified on-chain via the Pyth Lazer withdraw-script pattern:

1. Backend fetches a signed price update from the Pyth Lazer websocket.
2. Transaction includes a zero-withdrawal from the Pyth withdraw script with the update as redeemer.
3. The Pyth state UTxO is included as a reference input.
4. `pyth.get_updates(pyth_id, self)` reads the verified prices — no signature verification needed in the `bet` validator itself.

The `pyth_id` parameter is the Pyth deployment policy ID for the target network (preview / mainnet). This is the only thing that changes between environments.
