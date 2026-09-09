import type { EventRow, Store } from "./db.ts"

/// The pool's history, folded out of its events.
///
/// Nothing here reads the chain. It cannot: the node keeps state for about thirteen minutes, so
/// "what was the pool worth last Tuesday" has no answer through `eth_call` and never will. The
/// events are the only durable record, and every quantity below is recoverable from them exactly.
///
/// Each rule is the mirror of a line in SafixPool. They are listed against their source so that a
/// change to the contract has an obvious counterpart here, and so a reviewer can check the fold
/// against the thing it claims to follow rather than against a description of it.

export type PoolState = { deposits: bigint; debt: bigint }

export type PositionState = {
  collateral: bigint
  debt: bigint
  totalDrawn: bigint
  openedBlock: bigint
  lastBlock: bigint
}

const big = (value: string | undefined): bigint => (value === undefined ? 0n : BigInt(value))

const key = (borrower: string, asset: string) => `${borrower.toLowerCase()}:${asset.toLowerCase()}`

/// Folds a run of events onto a starting state, in place, returning what changed.
///
/// `pool` and `positions` are carried across calls so the sync loop can fold only the events it
/// just fetched. A reorg throws that continuity away and refolds from the first event, which is
/// why `rewindTo` empties the derived tables.
export class Fold {
  pool: PoolState = { deposits: 0n, debt: 0n }
  readonly positions = new Map<string, PositionState>()

  /// Applies events in chain order. Returns the pool points produced, so the caller can persist
  /// them alongside the events in the same transaction.
  apply(events: EventRow[]): { blockNumber: bigint; logIndex: number; timestamp: number | null; state: PoolState }[] {
    const points: { blockNumber: bigint; logIndex: number; timestamp: number | null; state: PoolState }[] = []

    // A liquidation's loss to providers is reduced by whatever the reserve paid. The reserve's
    // share is only in BadDebtRealised, which SafixPool emits from _settleShortfall before it
    // emits Liquidated — so by the time a Liquidated row is reached, its companion is already
    // known. Keyed by transaction, because a transaction can carry more than one liquidation.
    const reservePaid = new Map<string, bigint>()

    for (const event of events) {
      let movedPool = false

      switch (event.name) {
        // --- liquidity: SafixPool L627, L638 -------------------------------------------
        case "Deposited":
          this.pool.deposits += big(event.args.amount)
          movedPool = true
          break

        case "Withdrawn":
          this.pool.deposits -= big(event.args.amount)
          movedPool = true
          break

        // --- borrowing --------------------------------------------------------------------
        case "CollateralLocked": {
          const position = this.get(event)
          position.collateral += big(event.args.amount)
          this.touch(event, position)
          break
        }

        case "CollateralWithdrawn": {
          const position = this.get(event)
          position.collateral -= big(event.args.amount)
          this.touch(event, position)
          break
        }

        // The fee is part of the debt, not a charge beside it: SafixPool L697-L715 adds
        // `amount + fee`. An index that recorded only `amount` would show every borrower owing
        // slightly less than they do.
        case "Drawn": {
          const position = this.get(event)
          const amount = big(event.args.amount)
          const fee = big(event.args.fee)
          position.debt += amount + fee
          position.totalDrawn += amount
          this.pool.debt += amount + fee
          this.touch(event, position)
          movedPool = true
          break
        }

        case "Repaid": {
          const position = this.get(event)
          const amount = big(event.args.amount)
          position.debt -= amount
          this.pool.debt -= amount
          this.touch(event, position)
          movedPool = true
          break
        }

        // PositionClosed does not carry the debt it cleared, so the fold supplies it. This is the
        // one quantity in the pool's history that cannot be read off a single log, and the reason
        // the running position is worth keeping rather than recomputing per query.
        case "PositionClosed": {
          const position = this.get(event)
          this.pool.debt -= position.debt
          position.debt = 0n
          position.collateral = 0n
          position.totalDrawn = 0n
          this.touch(event, position)
          movedPool = true
          break
        }

        // --- losses ------------------------------------------------------------------------
        case "BadDebtRealised": {
          const previous = reservePaid.get(event.txHash) ?? 0n
          reservePaid.set(event.txHash, previous + big(event.args.fromReserve))
          break
        }

        case "Liquidated": {
          const position = this.get(event)
          const offset = big(event.args.debtOffset)
          const seized = big(event.args.collateralSeized)

          // SafixPool L860: the share of totalDrawn the liquidation takes leaves with it, so the
          // redemption fee at close is not charged twice on debt a liquidation already settled.
          const drawnOffset = position.debt > 0n ? (position.totalDrawn * offset) / position.debt : 0n
          position.debt -= offset
          position.collateral -= seized
          position.totalDrawn -= drawnOffset
          this.touch(event, position)

          this.pool.debt -= offset

          // SafixPool L806/L883: providers carry the debt cancelled, less whatever the reserve
          // paid on their behalf. With no shortfall there is no BadDebtRealised and the whole
          // offset falls on them — which is the ordinary case, and is not a loss: the pool bought
          // collateral with it.
          const fromReserve = reservePaid.get(event.txHash) ?? 0n
          const lpLoss = offset - (fromReserve > offset ? offset : fromReserve)
          this.pool.deposits -= lpLoss
          reservePaid.delete(event.txHash)

          movedPool = true
          break
        }

        default:
          // Everything else is history without arithmetic: attestations, partnership lifecycle,
          // feed changes. They are stored, queried and never folded.
          break
      }

      if (movedPool) {
        points.push({
          blockNumber: event.blockNumber,
          logIndex: event.logIndex,
          timestamp: event.timestamp,
          state: { deposits: this.pool.deposits, debt: this.pool.debt }
        })
      }
    }

    return points
  }

  private get(event: EventRow): PositionState {
    const borrower = (event.actor ?? "").toLowerCase()
    const asset = (event.asset ?? "").toLowerCase()
    const id = key(borrower, asset)
    let position = this.positions.get(id)
    if (!position) {
      position = { collateral: 0n, debt: 0n, totalDrawn: 0n, openedBlock: event.blockNumber, lastBlock: event.blockNumber }
      this.positions.set(id, position)
    }
    return position
  }

  private touch(event: EventRow, position: PositionState) {
    position.lastBlock = event.blockNumber
  }
}

/// Rebuilds every derived table from the stored events. Used after a reorg, and by `reconcile`
/// to prove the incremental fold and a full one agree.
export function rebuild(store: Store): Fold {
  const fold = new Fold()
  const events = store.allEventsInOrder()
  const points = fold.apply(events)
  for (const point of points) {
    store.writePoolPoint(point.blockNumber, point.logIndex, point.timestamp, point.state.deposits, point.state.debt)
  }
  persistPositions(store, fold)
  return fold
}

export function persistPositions(store: Store, fold: Fold) {
  for (const [id, position] of fold.positions) {
    const [borrower, asset] = id.split(":")
    store.writePosition({ borrower, asset, ...position })
  }
}
