use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use cardano/assets
use cardano/assets.{PolicyId}
use cardano/transaction.{Transaction}

// ── Redeemer ──────────────────────────────────────────────

pub type WinnerRedeemer {
  // Mints exactly 1 victory token with asset_name = duel_id.
  // Called by the backend in the same TX as Resolve.
  MintVictory { duel_id: ByteArray }

  // Burns one or more victory tokens (e.g. future leaderboard redemption).
  BurnVictory
}

// ── Helpers ───────────────────────────────────────────────

fn signed_by(tx: Transaction, pkh: VerificationKeyHash) -> Bool {
  list.has(tx.extra_signatories, pkh)
}

// ── Validator ─────────────────────────────────────────────
// Parameters:
//   backend_pkh — only the backend can authorize minting,
//                 so tokens can only be issued after a real Resolve TX.
//
// Usage:
//   The backend includes this mint alongside the Resolve spend in one TX.
//   That single atomic TX settles the duel AND awards the victory token.

validator winner_token(backend_pkh: VerificationKeyHash) {
  mint(
    redeemer: WinnerRedeemer,
    policy_id: PolicyId,
    self: Transaction,
  ) {
    when redeemer is {

      // ── MINT VICTORY ─────────────────────────────────────
      // Conditions:
      //   1. Backend signs the TX (only issued after a real Resolve)
      //   2. Exactly 1 token minted under this policy,
      //      with asset_name = duel_id (traceable back to the duel)
      MintVictory { duel_id } -> {
        let backend_ok = signed_by(self, backend_pkh)

        let mint_ok =
          when assets.tokens(self.mint, policy_id) |> dict.to_pairs is {
            [Pair(asset_name, quantity)] ->
              asset_name == duel_id && quantity == 1
            _ -> False
          }

        backend_ok && mint_ok
      }

      // ── BURN VICTORY ─────────────────────────────────────
      // Allows holders to burn their tokens (e.g. for future redemptions).
      // No backend signature required — the owner controls their token.
      BurnVictory -> {
        assets.tokens(self.mint, policy_id)
          |> dict.values()
          |> list.all(fn(q) { q == -1 })
      }
    }
  }

  else(_) { False }
}
