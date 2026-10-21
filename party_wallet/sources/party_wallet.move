// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Custody-agnostic wallet actions for a Party.
///
/// A Party ID is also an address: anyone may send objects or accumulator funds to it, while
/// only the matching `PartyAdminCap` exposes the UID needed to withdraw them. Every
/// withdrawn asset is returned to the caller so owners, Vault admins and other custody
/// systems compose the same API. Stores no Party data and defines no plugin or transfer
/// policy.
module party_wallet::party_wallet;

// === Imports ===

use sui::balance::Balance;
use sui::coin::Coin;
use sui::event::emit;
use sui::transfer::Receiving;
use hikida::hikida;
use miso_party::party::{Party, PartyAdminCap};

// === Errors ===

const ENothingToReceive: u64 = 0;
const ENoValueToRedeem: u64 = 1;

// === Events ===

public struct ObjectReceivedEvent<phantom Item> has copy, drop {
    party_id: ID,
    object_id: ID,
}

/// `coins` is the number of coin objects merged into `amount`.
public struct CoinsReceivedEvent<phantom Currency> has copy, drop {
    party_id: ID,
    amount: u64,
    coins: u64,
}

public struct FundsRedeemedEvent<phantom Currency> has copy, drop {
    party_id: ID,
    amount: u64,
}

// === Public Functions ===

/// Aborts if the ticket does not identify an object addressed to this Party.
public fun receive<Item: key + store>(
    party: &mut Party,
    admin_cap: &PartyAdminCap,
    object_to_receive: Receiving<Item>,
): Item {
    let party_id = object::id(party);
    let received = transfer::public_receive(party.uid_mut(admin_cap), object_to_receive);
    emit(ObjectReceivedEvent<Item> { party_id, object_id: object::id(&received) });
    received
}

/// Aborts if any ticket is invalid for this Party.
public fun receive_balance<Currency>(
    party: &mut Party,
    admin_cap: &PartyAdminCap,
    coins: vector<Receiving<Coin<Currency>>>,
): Balance<Currency> {
    assert!(!coins.is_empty(), ENothingToReceive);
    let party_id = object::id(party);
    let count = coins.length();
    let balance = hikida::receive_coins_as_balance(party.uid_mut(admin_cap), coins);
    emit(CoinsReceivedEvent<Currency> { party_id, amount: balance.value(), coins: count });
    balance
}

/// Unavailable funds abort in the Sui accumulator implementation.
public fun redeem_balance<Currency>(
    party: &mut Party,
    admin_cap: &PartyAdminCap,
    value: u64,
): Balance<Currency> {
    let party_id = object::id(party);
    let uid = party.uid_mut(admin_cap);
    assert!(value > 0, ENoValueToRedeem);
    let balance = hikida::redeem_balance<Currency>(uid, value);
    emit(FundsRedeemedEvent<Currency> { party_id, amount: balance.value() });
    balance
}

// === View Functions ===

public fun inbox_address(party: &Party): address {
    object::id(party).to_address()
}

// === Test Functions ===

#[test_only]
public fun object_received_event_fields<Item>(event: &ObjectReceivedEvent<Item>): (ID, ID) {
    (event.party_id, event.object_id)
}

#[test_only]
public fun coins_received_event_fields<Currency>(
    event: &CoinsReceivedEvent<Currency>,
): (ID, u64, u64) {
    (event.party_id, event.amount, event.coins)
}

#[test_only]
public fun funds_redeemed_event_fields<Currency>(
    event: &FundsRedeemedEvent<Currency>,
): (ID, u64) {
    (event.party_id, event.amount)
}
