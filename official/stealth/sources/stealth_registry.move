/// Optional on-chain directory mapping a Sui address to its public stealth
/// meta-address. This is a convenience for discovery (so a sender can look up
/// "what are Alice's stealth pubkeys") — it is NOT required by the protocol:
/// meta-addresses can equally be shared off-chain (see resolve.ts encoding).
///
/// Registering reveals only PUBLIC keys; it never exposes spend authority.
module stealth::stealth_registry;

use sui::table::{Self, Table};

/// A registered pubkey was not the required 33-byte compressed length.
const EInvalidPubkeyLength: u64 = 0;
/// Tried to deregister/resolve an address that is not registered.
const ENotRegistered: u64 = 1;

/// Required length of a compressed secp256k1 public key.
const PUBKEY_LEN: u64 = 33;

/// A recipient's public meta-address (both keys are PUBLIC).
public struct MetaAddress has store, copy, drop {
    /// Curve / derivation scheme (1 = secp256k1, this protocol).
    scheme_id: u8,
    /// Compressed spend public key (33 bytes).
    spend_pubkey: vector<u8>,
    /// Compressed view public key (33 bytes).
    view_pubkey: vector<u8>,
}

/// Shared directory of address -> MetaAddress.
public struct Registry has key {
    id: UID,
    entries: Table<address, MetaAddress>,
}

/// Module initializer: create and share the singleton Registry on publish.
fun init(ctx: &mut TxContext) {
    transfer::share_object(Registry {
        id: object::new(ctx),
        entries: table::new(ctx),
    });
}

/// Register (or update) the caller's meta-address. Keyed by the sender, so a
/// caller can only ever set their own entry. Aborts if either pubkey is not
/// exactly 33 bytes.
public fun register(
    reg: &mut Registry,
    scheme_id: u8,
    spend_pubkey: vector<u8>,
    view_pubkey: vector<u8>,
    ctx: &TxContext,
) {
    assert!(spend_pubkey.length() == PUBKEY_LEN, EInvalidPubkeyLength);
    assert!(view_pubkey.length() == PUBKEY_LEN, EInvalidPubkeyLength);

    let who = ctx.sender();
    let meta = MetaAddress { scheme_id, spend_pubkey, view_pubkey };

    if (reg.entries.contains(who)) {
        *reg.entries.borrow_mut(who) = meta;
    } else {
        reg.entries.add(who, meta);
    };
}

/// Remove the caller's registration. Aborts if not registered.
public fun deregister(reg: &mut Registry, ctx: &TxContext) {
    let who = ctx.sender();
    assert!(reg.entries.contains(who), ENotRegistered);
    reg.entries.remove(who);
}

/// Borrow the meta-address registered for `owner`. Aborts if not registered.
public fun resolve(reg: &Registry, owner: address): &MetaAddress {
    assert!(reg.entries.contains(owner), ENotRegistered);
    reg.entries.borrow(owner)
}

/// Whether `owner` has a registration.
public fun has(reg: &Registry, owner: address): bool {
    reg.entries.contains(owner)
}

// --- MetaAddress field accessors ---

public fun scheme_id(meta: &MetaAddress): u8 { meta.scheme_id }

public fun spend_pubkey(meta: &MetaAddress): vector<u8> { meta.spend_pubkey }

public fun view_pubkey(meta: &MetaAddress): vector<u8> { meta.view_pubkey }

#[test_only]
/// Run the module initializer from a test (init is private otherwise).
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
