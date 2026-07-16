// Copyright (c) ZZYZX Labs
// SPDX-License-Identifier: BUSL-1.1

/// Sup Wallet adaptor for Bluefin Pro MARGIN movements.
///
/// Lets the managed agent DEPOSIT margin coin from the vault into the user's
/// Bluefin Pro account WITHOUT a per-action owner signature — bounded by the
/// owner's per-service + per-coin allowances (the standard Sup capped-spend), with
/// the deposit destination LOCKED to a Bluefin account the owner bound once. So the
/// agent can move at most what the owner authorized, and only into the owner's own
/// Bluefin account.
///
/// Out of scope here (by design):
///   - Trades: stay OFF-CHAIN (agent = Bluefin trade-only sub-account, signs orders
///     via REST). Nothing on-chain.
///   - Withdrawals: stay OWNER-SIGNED (Bluefin enforces owner-only withdraw; the
///     trade-only agent can never withdraw). Handled as an owner-signed app flow,
///     not an adaptor entry.
///
/// Custody shape mirrors `adaptor_aftermath_perp`, minus the on-chain trade/withdraw
/// entries: Bluefin Pro is an off-chain orderbook with no on-chain account cap to
/// custody, so we only pin the bound Bluefin account address + the parent vault.
///
/// See Protocols/sup-wallet/docs/bluefin-margin-adapter.md.
///
/// ⚠ DRAFT — `bluefin_exchange::exchange` is an ABI stub reconstructed from the web
/// deposit PTB; not yet Move-compiled against the real Bluefin package. VERIFY the
/// deposit ABI and AUDIT before mainnet.
module adaptor_bluefin_margin::adaptor {
    use std::string::String;
    use sui::coin;
    use sui::event;
    use SupWallet::intent;
    use SupWallet::wallet::{Self, Wallet};
    use bluefin_exchange::exchange;
    use bluefin_exchange::data_store::ExternalDataStore;

    /// Service witness. The owner grants this service per coin type on the vault
    /// (for deposits) exactly like every other adaptor.
    public struct BluefinMarginAdaptor has drop {}

    /// Sup-custodied binding: which Bluefin Pro account this vault's agent may
    /// deposit into. Shared, parented to one vault. No funds or caps live here — it
    /// only pins the deposit destination so the agent cannot redirect it.
    public struct BluefinMarginAccount has key {
        id: UID,
        /// `wallet::identity(vault)` — the only vault allowed to drive this binding.
        parent_wallet_identity: address,
        /// The owner's Bluefin Pro account — the deposit destination LOCK.
        bluefin_account: address,
    }

    /// Emitted on `adopt` so off-chain clients can DISCOVER the shared binding
    /// object for a vault (it carries no owner, so it can't be found by
    /// owned-object queries). `wallet_id` is the Wallet object id the app already
    /// holds; `binding_id` is the shared BluefinMarginAccount to pass to deposits.
    public struct BluefinMarginAccountAdopted has copy, drop {
        wallet_id: ID,
        binding_id: ID,
        bluefin_account: address,
    }

    const ENotOwner: u64 = 0;
    const EWrongParent: u64 = 1;
    const EZeroAmount: u64 = 2;

    // ===== owner setup (owner-signed, one-time) =====

    /// Bind a Bluefin Pro account to this vault and share the binding. Owner-signed.
    /// Returns the binding id.
    public fun adopt(sup_wallet: &Wallet, bluefin_account: address, ctx: &mut TxContext): ID {
        assert!(ctx.sender() == wallet::owner(sup_wallet), ENotOwner);
        let self = BluefinMarginAccount {
            id: object::new(ctx),
            parent_wallet_identity: wallet::identity(sup_wallet),
            bluefin_account,
        };
        let id = object::id(&self);
        event::emit(BluefinMarginAccountAdopted {
            wallet_id: object::id(sup_wallet),
            binding_id: id,
            bluefin_account,
        });
        transfer::share_object(self);
        id
    }

    /// Re-point the bound Bluefin account. Owner-signed.
    public fun set_account(
        sup_wallet: &Wallet,
        self: &mut BluefinMarginAccount,
        bluefin_account: address,
        ctx: &TxContext,
    ) {
        assert!(ctx.sender() == wallet::owner(sup_wallet), ENotOwner);
        assert_parent(sup_wallet, self);
        self.bluefin_account = bluefin_account;
    }

    /// Delete the binding. Owner-signed. (The spend caps are revoked separately via
    /// `delegate` / `wallet::revoke_service`.)
    public fun reclaim(sup_wallet: &Wallet, self: BluefinMarginAccount, ctx: &TxContext) {
        assert!(ctx.sender() == wallet::owner(sup_wallet), ENotOwner);
        assert_parent(sup_wallet, &self);
        let BluefinMarginAccount { id, parent_wallet_identity: _, bluefin_account: _ } = self;
        object::delete(id);
    }

    // ===== agent op: deposit (NO per-action owner signature; gated by intent caps) =====

    /// Deposit `amount` of margin coin `T` FROM the vault into the bound Bluefin
    /// account. Funds are pulled via `intent::validate_and_pay`, which enforces the
    /// caller's per-service + per-coin allowance on the vault — so the agent can
    /// only move what the owner authorized, and only into `self.bluefin_account`.
    public fun deposit_margin<T>(
        sup_wallet: &mut Wallet,
        self: &BluefinMarginAccount,
        eds: &mut ExternalDataStore,
        symbol: String,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        assert!(amount > 0, EZeroAmount);
        assert_parent(sup_wallet, self);

        let tag = self.parent_wallet_identity;
        let sig = intent::request_payment<BluefinMarginAdaptor, T>(BluefinMarginAdaptor {}, amount, tag);
        let (mut coin_in, wallet_witness) =
            intent::validate_and_pay<BluefinMarginAdaptor, T>(sup_wallet, sig, ctx);

        // Destination is self.bluefin_account (owner-bound); the agent cannot
        // redirect the deposit to any other Bluefin account.
        // VERIFY: deposit borrows `&mut Coin` and leaves it zero (web PTB transfers
        // the remainder back). If the real ABI takes the coin by value, hand it over
        // by value here and drop the destroy_zero.
        exchange::deposit_to_asset_bank<T>(eds, symbol, self.bluefin_account, amount, &mut coin_in, ctx);
        coin::destroy_zero(coin_in);

        let receipt =
            intent::create_receipt_sig<BluefinMarginAdaptor, T>(BluefinMarginAdaptor {}, amount, tag);
        intent::verify_and_clear<BluefinMarginAdaptor, T>(wallet_witness, receipt);
    }

    /// Deposit margin with the amount split into the TWO precisions the flow needs.
    ///
    /// `deposit_margin` above reused a single `amount` for both the vault withdrawal
    /// AND Bluefin's asset-bank amount — but they are in different units: the vault
    /// coin is NATIVE precision (e.g. USDC = 1e6) while Bluefin accounts every balance
    /// in E9 (USDC = 1e9). Its `deposit_to_asset_bank` coin-value↔amount check then
    /// fails (`abort 1030`) for any sub-9-decimal asset — i.e. always, since margin is
    /// USDC. This entrypoint takes both: `amount_native` is withdrawn from the vault
    /// (bounds the capped spend), `amount_e9` is what the asset bank checks against.
    /// The caller knows the asset's decimals and computes both.
    public fun deposit_margin_e9<T>(
        sup_wallet: &mut Wallet,
        self: &BluefinMarginAccount,
        eds: &mut ExternalDataStore,
        symbol: String,
        amount_native: u64,
        amount_e9: u64,
        ctx: &mut TxContext,
    ) {
        assert!(amount_native > 0, EZeroAmount);
        assert_parent(sup_wallet, self);

        let tag = self.parent_wallet_identity;
        let sig = intent::request_payment<BluefinMarginAdaptor, T>(BluefinMarginAdaptor {}, amount_native, tag);
        let (mut coin_in, wallet_witness) =
            intent::validate_and_pay<BluefinMarginAdaptor, T>(sup_wallet, sig, ctx);

        exchange::deposit_to_asset_bank<T>(eds, symbol, self.bluefin_account, amount_e9, &mut coin_in, ctx);
        coin::destroy_zero(coin_in);

        let receipt =
            intent::create_receipt_sig<BluefinMarginAdaptor, T>(BluefinMarginAdaptor {}, amount_native, tag);
        intent::verify_and_clear<BluefinMarginAdaptor, T>(wallet_witness, receipt);
    }

    // ===== reads / internal =====

    public fun bluefin_account(self: &BluefinMarginAccount): address { self.bluefin_account }

    public fun parent_identity(self: &BluefinMarginAccount): address { self.parent_wallet_identity }

    public fun assert_parent(sup_wallet: &Wallet, self: &BluefinMarginAccount) {
        assert!(self.parent_wallet_identity == wallet::identity(sup_wallet), EWrongParent);
    }

    #[test_only]
    public fun not_owner_error(): u64 { ENotOwner }

    #[test_only]
    public fun wrong_parent_error(): u64 { EWrongParent }

    #[test_only]
    public fun zero_amount_error(): u64 { EZeroAmount }
}
