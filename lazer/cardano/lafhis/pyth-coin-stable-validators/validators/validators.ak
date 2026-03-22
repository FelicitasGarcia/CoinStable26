use aiken/collection/list
use aiken/math/rational
use aiken/bytearray
use aiken/crypto.{VerificationKeyHash, sha2_256}
use cardano/assets.{PolicyId, lovelace_of, quantity_of}
use cardano/transaction.{OutputReference, Transaction, InlineDatum}
use pyth
use types/u32

// ── Types ─────────────────────────────────────────────────

pub type DuelStatus {
  Waiting
  Active
  Finished
}

pub type Player {
  pkh:         VerificationKeyHash,
  feed_id:     Int,         // Pyth Pro feed ID (ej: 16 = ADA/USD)
  start_price: Option<Int>, // Precio snapshot al inicio del duelo (set en Join)
}

pub type DuelDatum {
  duel_id:             ByteArray,
  player_a:            Player,
  player_b:            Option<Player>,
  bet_amount_lovelace: Int,
  status:              DuelStatus,
  deadline:            Option<Int>, // POSIX ms; el duelo resuelve después de esto
}

pub type DuelRedeemer {
  // Player B se une; el backend incluye el Pyth withdrawal en la misma TX
  Join { player_pkh: VerificationKeyHash, feed_id: Int }

  // El backend resuelve post-deadline; los precios vienen del Pyth withdrawal
  Resolve { timestamp: Int }

  // Cancela si nadie se sumó aún
  Cancel
}

// ── Helpers generales ─────────────────────────────────────

fn signed_by(tx: Transaction, pkh: VerificationKeyHash) -> Bool {
  list.has(tx.extra_signatories, pkh)
}

// Retorna cambio porcentual escalado x1_000_000 (1% = 10_000)
fn percent_change(start: Int, end: Int) -> Int {
  (end - start) * 1_000_000 / start
}

fn abs(n: Int) -> Int {
  if n >= 0 { n } else { -n }
}

// Deriva el duel_id desde el OutputReference del UTxO.
// Evita que alguien reutilice un duel_id preexistente con un UTxO falso.
fn duel_id_from_utxo(utxo: OutputReference) -> ByteArray {
  let OutputReference { transaction_id, output_index } = utxo
  sha2_256(
    bytearray.concat(
      transaction_id.hash,
      bytearray.from_int(output_index),
    ),
  )
}

fn pays_to(o: Output, pkh: VerificationKeyHash) -> Bool {
  o.address.payment_credential == VerificationKey(pkh)
}

// Extrae el upper bound del validity range como tiempo actual confiable.
// En Cardano no hay "now" global; el upper bound es el máximo posible.
fn tx_upper_bound(tx: Transaction) -> Option<Int> {
  when tx.validity_range.upper_bound.bound_type is {
    Finite(t) -> Some(t)
    _         -> None
  }
}

// ── Pyth helpers ──────────────────────────────────────────

// Lee el precio de un feed específico desde los updates verificados por Pyth.
// pyth.get_updates garantiza que las firmas son válidas — nosotros solo
// buscamos el feed_id que nos interesa.
//
// Retorna el precio como Int (ya escalado por el exponent de Pyth).
fn get_price_from_pyth(
  pyth_id: PolicyId,
  tx:      Transaction,
  feed_id: Int,
) -> Option<Int> {
  // get_updates lee el redeemer del Pyth withdrawal script en esta TX.
  // Si el withdrawal no está presente o la firma es inválida, falla.
  let updates = pyth.get_updates(pyth_id, tx)

  // Puede haber múltiples updates en una TX; buscamos en todos
  list.find_map(updates, fn(update) {
    list.find_map(update.feeds, fn(feed) {
      if u32.as_int(feed.feed_id) == feed_id {
        // Convertir precio a Int aplicando el exponent
        // price_raw * 10^exponent da el precio en USD
        when (feed.price, feed.exponent) is {
          (Some(Some(p)), Some(exp)) -> {
            // Escalamos a Int: multiplicamos por 10^exp
            // Usamos rational para no perder precisión en el camino
            let scaled =
              rational.from_int(p)
                |> rational.mul(
                     rational.from_int(10)
                       |> rational.pow(exp)
                       |> rational.or_else(rational.from_int(1)),
                   )
                |> rational.truncate()
            Some(scaled)
          }
          _ -> None
        }
      } else {
        None
      }
    })
  })
}

// ── Continuing Output ──────────────────────────────────────

// Verifica que exista un UTxO de salida con el duel_id correcto y el NFT
// de autenticidad. Usado en Join para garantizar continuidad del estado.
fn find_continuing_output(
  tx:        Transaction,
  duel_id:   ByteArray,
  policy_id: PolicyId,
) -> Option<(DuelDatum, Int)> {
  list.find_map(tx.outputs, fn(o) {
    when o.datum is {
      InlineDatum(raw) ->
        when raw is {
          DuelDatum { duel_id: id, .. } if id == duel_id -> {
            let has_nft = quantity_of(o.value, policy_id, duel_id) == 1
            if has_nft { Some((raw, lovelace_of(o.value))) }
            else       { None }
          }
          _ -> None
        }
      _ -> None
    }
  })
}

// ── Main Validator ─────────────────────────────────────────

validator bet(
  backend_pkh:   VerificationKeyHash,
  nft_policy_id: PolicyId,
  pyth_id:       PolicyId, // Policy ID del deployment de Pyth en esta red
) {
  spend(
    datum:    Option<DuelDatum>,
    redeemer: DuelRedeemer,
    utxo:     OutputReference,
    self:     Transaction,
  ) {
    when datum is {
      None -> False
      Some(d) -> {
        // El duel_id en el datum debe derivarse de este UTxO específico
        let id_matches = d.duel_id == duel_id_from_utxo(utxo)

        // No se deben mintear NFTs de esta policy en TXs intermedias
        let no_extra_mint =
          quantity_of(self.mint, nft_policy_id, d.duel_id) == 0

        let base_ok = id_matches && no_extra_mint

        base_ok &&
          when redeemer is {

            // ── JOIN ────────────────────────────────────
            // Player B se une al duelo.
            // La TX debe incluir:
            //   - Un zero-withdrawal del Pyth script con los signed updates
            //   - El Pyth state UTxO como reference input
            //   - Un continuing output con status=Active y ambos start_prices
            //
            // El validador verifica que los precios del datum de salida
            // coincidan con lo que Pyth reporta en esta TX.
            Join { player_pkh, feed_id } -> {
              let is_waiting      = d.status == Waiting
              let not_player_a    = player_pkh != d.player_a.pkh
              let no_opponent_yet = d.player_b == None
              let backend_ok      = signed_by(self, backend_pkh)
              let diff_asset      = feed_id != d.player_a.feed_id

              // Leer start prices desde Pyth (verificados criptográficamente)
              let price_a_opt = get_price_from_pyth(pyth_id, self, d.player_a.feed_id)
              let price_b_opt = get_price_from_pyth(pyth_id, self, feed_id)

              let output_ok =
                when (price_a_opt, price_b_opt) is {
                  (Some(pa), Some(pb)) ->
                    when find_continuing_output(self, d.duel_id, nft_policy_id) is {
                      None -> False
                      Some((out_datum, out_lovelace)) -> {
                        // El pozo debe ser exactamente 2× la apuesta individual
                        let amount_ok =
                          out_lovelace == d.bet_amount_lovelace * 2

                        // El datum de salida debe reflejar el nuevo estado
                        // con los precios leídos de Pyth
                        let datum_ok =
                          out_datum.status == Active                        &&
                          out_datum.player_a.start_price == Some(pa)        &&
                          (when (out_datum.deadline, out_datum.player_b) is {
                            (Some(dl), Some(pb_out)) ->
                              dl > 0                           &&
                              pb_out.pkh == player_pkh         &&
                              pb_out.feed_id == feed_id        &&
                              pb_out.start_price == Some(pb)
                            _ -> False
                          })

                        amount_ok && datum_ok
                      }
                    }
                  // Si Pyth no tiene precio para alguno de los feeds, rechazar
                  _ -> False
                }

              is_waiting      &&
              not_player_a    &&
              no_opponent_yet &&
              backend_ok      &&
              diff_asset      &&
              output_ok
            }

            // ── RESOLVE ──────────────────────────────────
            // El backend llama esto post-deadline.
            // Los precios finales se leen del Pyth withdrawal en esta TX —
            // el backend NO puede manipularlos, solo elegir el timing.
            //
            // Ganador: el asset con mayor % de cambio desde su start_price.
            // Empate: diferencia < 1% → ambos recuperan su depósito.
            Resolve { timestamp } -> {
              let is_active  = d.status == Active
              let backend_ok = signed_by(self, backend_pkh)

              let deadline_passed =
                when d.deadline is {
                  None     -> False
                  Some(dl) -> timestamp >= dl
                }

              let payout_ok =
                when d.player_b is {
                  None -> False
                  Some(pb) -> {
                    // Leer precios finales de Pyth
                    let end_a_opt = get_price_from_pyth(pyth_id, self, d.player_a.feed_id)
                    let end_b_opt = get_price_from_pyth(pyth_id, self, pb.feed_id)

                    when (d.player_a.start_price, pb.start_price, end_a_opt, end_b_opt) is {
                      (Some(sa), Some(sb), Some(end_a), Some(end_b)) -> {
                        let change_a = percent_change(sa, end_a)
                        let change_b = percent_change(sb, end_b)
                        let total    = d.bet_amount_lovelace * 2
                        let is_draw  = abs(change_a - change_b) < 10_000

                        if is_draw {
                          // Empate: cada jugador recupera su depósito original
                          let a_ok = list.any(self.outputs, fn(o) {
                            pays_to(o, d.player_a.pkh) &&
                            lovelace_of(o.value) >= d.bet_amount_lovelace
                          })
                          let b_ok = list.any(self.outputs, fn(o) {
                            pays_to(o, pb.pkh) &&
                            lovelace_of(o.value) >= d.bet_amount_lovelace
                          })
                          a_ok && b_ok
                        } else {
                          // El ganador se lleva el pozo completo
                          let winner =
                            if change_a > change_b { d.player_a.pkh }
                            else                   { pb.pkh }
                          list.any(self.outputs, fn(o) {
                            pays_to(o, winner) &&
                            lovelace_of(o.value) >= total
                          })
                        }
                      }
                      // Sin start_prices o sin precios de Pyth → rechazar
                      _ -> False
                    }
                  }
                }

              is_active       &&
              backend_ok      &&
              deadline_passed &&
              payout_ok
            }

            // ── CANCEL ────────────────────────────────────
            // Solo válido en Waiting (nadie se sumó todavía).
            // Player A o el backend pueden cancelar.
            // El NFT debe quemarse y Player A recupera su depósito.
            Cancel -> {
              let is_waiting  = d.status == Waiting
              let no_opponent = d.player_b == None
              let authorized  =
                signed_by(self, d.player_a.pkh) ||
                signed_by(self, backend_pkh)
              let refund_ok   = list.any(self.outputs, fn(o) {
                pays_to(o, d.player_a.pkh) &&
                lovelace_of(o.value) >= d.bet_amount_lovelace
              })
              let nft_burned  =
                quantity_of(self.mint, nft_policy_id, d.duel_id) == -1

              is_waiting  &&
              no_opponent &&
              authorized  &&
              refund_ok   &&
              nft_burned
            }
          }
      }
    }
  }

  else(_) { False }
}
