# Security Audit — `party_wallet`

Audited at `ba33a92089d11411b1dcfe3c3612cee99c7d0075` (2026-10-21). Scope: package `party_wallet`, module `party_wallet::party_wallet` (`party_wallet/sources/party_wallet.move`), together with the pinned dependencies it relies on for safety: `miso_party::party` (party-protocol `8e59a81`, identical in source to party-protocol main `7e2f64f`) and `hikida::hikida` (`c91d6a0`, hikida main), and the Sui framework's `transfer::public_receive` and `funds_accumulator`. The `vault` dependency is test-only. Later commits only apply naming and ordering standards; line references are to the current code.

## What it does

Three stateless actions on a Party's two inboxes: `receive` one `key + store` object sent to the Party address, `receive_balance` a batch of `Coin<Currency>` objects merged into one `Balance`, and `redeem_balance` an amount from the Party address's funds accumulator. Each returns the asset to the caller for same-PTB composition and emits one event. See [README](./README.md) and [`party_wallet/README.md`](./party_wallet/README.md).

## Trust model

- **`PartyAdminCap` holder for the exact Party:** the only actor. All three mutating functions obtain the Party UID through `party.uid_mut(admin_cap)` (`party_wallet.move:52,65,76`), which aborts `miso_party::party::EUnauthorized` unless `cap.party_id == object::id(party)` (`party.move:262-271`). The cap is `key + store`; whoever holds or borrows it (directly, from a Vault, or from any custody system) has full wallet control. Nothing distinguishes individual from group Parties.
- **Anyone:** `inbox_address` view (`party_wallet.move:40`); sending objects or funds to the Party address (framework behavior, outside this package).
- **Nobody can:** receive without the matching cap, receive an object not owned by the Party address (native `Receiving` failure), receive a non-`store` object (`public_receive` bound), or redeem more than the accumulator holds (`sui::funds_accumulator::EObjectFundsInsufficient`, enforced by the framework natives; see Verification).
- The package stores no data, holds no funds, has no `entry` functions, no shared or owned objects of its own and no upgrade-sensitive state.

## Findings

**PW-01 — Info — Open — Check order differs between `receive_balance` and `redeem_balance`.**
`receive_balance` asserts non-empty input (`party_wallet.move:62`) before authorizing (`:65`); `redeem_balance` authorizes (`:76`) before the zero check (`:77`). Probe: wrong cap + empty vector aborts `ENothingToReceive`, wrong cap + zero value aborts `EUnauthorized`. No security impact (both abort). Suggested fix: authorize first in both for a consistent abort surface.

**PW-02 — Info — Open — Package code `0` coincides with `miso_party::party::EUnauthorized = 0`.**
`ENothingToReceive = 0` (`party_wallet.move:17`). The abort location disambiguates on chain, but tooling that matches only on code can confuse the two. Suggested fix: not needed if decoders use the location; otherwise renumber in a future major version (published signatures and codes are v1 API).

**PW-03 — Info — Accepted — `receive` hands the caller any `key + store` object the Party address owns.**
That includes other Parties' `PartyAdminCap`s (probe), share coins or stakes parked at the Party address, and any `Coin`. This is the intended admin power; it is also why the README rules out a permissionless wallet plugin, since a Vault plugin borrowing the `PartyAdminCap` gets the same power.

**PW-04 — Info — Open — The suite's wrong-address ticket test accepts any abort.**
`receive_rejects_a_ticket_for_another_address` (`party_wallet/tests/party_wallet_tests.move:224-240`) is `#[test, expected_failure]` with no code or location, so an abort anywhere in the body passes it. The README's claim that it "can no longer pass because of an unrelated terminal abort" is overstated. Suggested fix: pin `location = sui::transfer` (or the actual native failure) if the test framework exposes it; otherwise reword the README.

## Checked, no finding

- **Authorization:** every mutating path goes through `uid_mut`; a cap for another Party fails (`party_wallet_tests.move:208-222,399-409`); the `&mut UID` is used only for `public_receive` / `withdraw_funds_from_object` and never stored or exposed.
- **Money conservation:** `receive_balance` returns exactly the sum of the received coins (hikida `receive_balance_impl` joins each coin's balance; coins are consumed), and `CoinsReceivedEvent.amount` equals that sum (`party_wallet.move:66`); zero-valued coins are accepted and yield a zero `Balance` the caller must destroy. `redeem_balance` returns a `Balance` of exactly `value` or aborts; `FundsRedeemedEvent.amount` is that value. No rounding, no fees, no dust created; funds left in the accumulator remain redeemable.
- **Double-receive / double-redeem:** a duplicate `Receiving` ticket in one batch fails (probe). Redeeming the full balance and then one more unit aborts `EObjectFundsInsufficient` (probe); the pre-existing suite's partial redemptions sum exactly to the funded amount (`party_wallet_tests.move:281-309`).
- **Solvency in the unit-test VM:** at the pinned framework (Sui `719fb29`, sui 1.82.1) `funds_accumulator::reserve_object_funds_for_withdrawal` aborts with code `5` on overdraw, so the Move VM does enforce solvency. The README still says it does not (see Operational requirements).
- **Receiving bounds:** `receive<Item: key + store>` and `public_receive` reject non-`store` objects at the type level; a ticket for an object owned by another address is a native failure (`party_wallet_tests.move:224-240`).
- **Events:** one event per call, after the operation succeeds, with `party_id` plus the business amount/ID; `receive_balance` reports the input count rather than coin IDs (tx inputs carry provenance). A redemption that fails on the validator commits no event (framework abort semantics).
- **Vault test-only dependency:** `vault` is pinned at `b39cbba` with `modes = ["test"]`; mainnet and testnet builds list only `hikida` and `miso_party`, so the published bytecode has no vault dependency. Vault main (`1661860`) differs from `b39cbba` only by removed comments, a contact-email change and the `share(vault)` → `share(self)` parameter rename; the tests call `vault.share()` by method syntax and compile against both. The stale pin has no effect on safety or on the suite.
- **Dependency pins:** `miso_party` `8e59a81` has the same `sources/` as party-protocol main `7e2f64f` (only `AUDIT.md` differs); `hikida` `c91d6a0` is hikida main.
- **Limits:** no loops in this module beyond hikida's per-coin fold; each `Receiving` is a transaction input, so batch size is bounded by the PTB input limit, not by this package. One event per call.
- **Object lifecycle:** the package defines no objects; `Party` is shared by its own module and cannot be deleted or transferred here.

## Operational requirements

- Never send a Party's only matching `PartyAdminCap` to that Party's own inbox (circular lock, README).
- Funds deposited by earlier transactions become redeemable only after settlement at a checkpoint boundary; a redemption immediately after a deposit may abort with `EObjectFundsInsufficient` even though the deposit succeeded. Deposits within the same transaction are counted (framework `funds_accumulator::withdraw_from_object` note). Tooling should retry or wait for settlement.
- Callers must consume the returned `Balance` (including zero balances) and the returned `Item` in the same PTB.
- Update `party_wallet/README.md`: the unit-test VM now enforces accumulator solvency, so an overdraw unit test is possible; the "Accumulator testing boundary" paragraph lists an overdraw path the suite does not contain.

## Verification

- `sui move test --coverage --build-env testnet` (sui 1.82.1): 15/15 passed.
- `sui move coverage summary`: 100.00% for `party_wallet::party_wallet`.
- `sui move build --build-env mainnet` and `--build-env testnet`: both succeed with no warnings; neither includes `vault`.
- Throwaway probe tests (not committed): duplicate ticket, overdraw by one after a full drain, large overdraw, check-order probes, and receiving a foreign `PartyAdminCap`: all behaved as stated above.
- `e2e/wallet.localnet.ts` was not run to completion in the audit environment: the ephemeral localnet did not come up within the runner's timeout. The overdraw boundary it tests is covered in the unit-test VM at the pinned framework (see above).
