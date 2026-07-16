/// Stateless EIP-5564-style announcer.
///
/// The sender emits an `Announcement` event for every stealth payment. There is
/// NO shared state and NO coordinator — recipients scan these events off-chain
/// and locally test each one against their viewing key. The chain only carries
/// the public hints (ephemeral pubkey, view tag, stealth address).
module stealth::announcer;

use sui::event;

/// Scheme identifier for this protocol (secp256k1 + keccak256 HASH_TO_SCALAR).
const SCHEME_SECP256K1: u8 = 1;

/// Emitted once per stealth payment. All fields are public hints; none of them
/// link the payment to the recipient without their viewing key.
public struct Announcement has copy, drop {
    /// Curve / derivation scheme (1 = secp256k1, this protocol).
    scheme_id: u8,
    /// Compressed ephemeral public key R (33 bytes).
    ephemeral_pubkey: vector<u8>,
    /// 1-byte view tag — a cheap scan filter.
    view_tag: u8,
    /// The stealth address the sender funded (a hint; recipients re-derive it).
    stealth_address: address,
    /// Opaque metadata (encrypted memo etc. — out of scope for v1).
    metadata: vector<u8>,
    /// The address that emitted this announcement.
    sender: address,
}

/// Emit an announcement for a stealth payment. Stateless — anyone can call it.
/// `scheme_id` is passed by the caller so future schemes can coexist.
public fun announce(
    scheme_id: u8,
    ephemeral_pubkey: vector<u8>,
    view_tag: u8,
    stealth_address: address,
    metadata: vector<u8>,
    ctx: &TxContext,
) {
    event::emit(Announcement {
        scheme_id,
        ephemeral_pubkey,
        view_tag,
        stealth_address,
        metadata,
        sender: ctx.sender(),
    });
}

/// Convenience wrapper that fixes `scheme_id` to the secp256k1 scheme.
public fun announce_secp256k1(
    ephemeral_pubkey: vector<u8>,
    view_tag: u8,
    stealth_address: address,
    metadata: vector<u8>,
    ctx: &TxContext,
) {
    announce(SCHEME_SECP256K1, ephemeral_pubkey, view_tag, stealth_address, metadata, ctx);
}
