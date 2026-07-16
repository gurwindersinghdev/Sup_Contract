// Copyright (c) ZZYZX Labs
// SPDX-License-Identifier: BUSL-1.1

/// Sup Wallet adaptor for Current Finance — the full money-market surface
/// (lending / borrowing) plus the building blocks Multiply / Margin compose with.
///
/// Custody model (mirrors `adaptor_aftermath_perp`): a Sup-custodied shared
/// `CurrentObligation<MarketT>` holds the Current `ObligationOwnerCap` (never
/// handed out), is parented to one vault identity, and carries a permission ACL.
/// Every fund movement is either funded from the vault via the Sup intent (caps
/// enforced) or credited back into the vault via `receive_from_service` — there is
/// NO path that returns funds to the caller, so the agent can supply / repay /
/// borrow / withdraw within the owner's caps but can never exfiltrate.
///
/// Phases:
///   1. supply_from_vault / repay_from_vault / withdraw_to_vault   (lending)
///   2. borrow_to_vault                                            (borrowing)
///   3. supply_coin / borrow_coin / flash_borrow / flash_repay     (Multiply / Margin,
///      composed with a swap in the PTB — see docs/current-adapter.md)
///
/// Risk: borrow / multiply / margin take on debt + leverage. Current's own risk
/// engine reverts unsafe borrows; on top, gate the delegate with conservative
/// per-coin / per-service caps + max-leverage + the daily-action guard + freeze.
///
/// ⚠ DRAFT — `current_protocol::*` is an ABI stub (signatures read from the live
/// mainnet package, bodies abort; `x_oracle` is stubbed and must point at the real
/// oracle package at deploy). Not yet Move-compiled against the real packages.
/// VERIFY + AUDIT before mainnet. See Protocols/sup-wallet/docs/current-adapter.md.
module adaptor_current_lending::adaptor {
    use sui::clock::Clock;
    use sui::coin::Coin;
    use sui::event;
    use sui::vec_map::{Self, VecMap};
    use SupWallet::intent;
    use SupWallet::wallet::{Self, Wallet};
    use current_protocol::app::{ProtocolApp, PackageCallerCap};
    use current_protocol::market::{Market, FlashLoan};
    use current_protocol::obligation::ObligationOwnerCap;
    use current_protocol::coin_decimals_registry::CoinDecimalsRegistry;
    use current_x_oracle::x_oracle::XOracle;
    use current_protocol::enter_market;
    use current_protocol::deposit;
    use current_protocol::withdraw;
    use current_protocol::borrow;
    use current_protocol::repay;
    use current_protocol::flash_loan;

    /// Service witness. The owner grants this service per coin type on the vault
    /// (for supply / repay funding) exactly like every other adaptor.
    public struct CurrentLendingAdaptor has drop {}

    /// Sup-custodied Current obligation, parented to a vault. Holds the obligation
    /// cap; the cap never leaves except via owner `reclaim`.
    public struct CurrentObligation<phantom MarketT> has key {
        id: UID,
        /// `wallet::identity(vault)` — the only vault allowed to drive this.
        parent_wallet_identity: address,
        /// Current's obligation cap — locked inside.
        obligation_cap: ObligationOwnerCap,
        /// delegate address -> permission bitmask.
        delegates: VecMap<address, u32>,
    }

    /// Emitted on `adopt` so off-chain clients can DISCOVER the shared, vault-
    /// parented obligation wrapper (it carries no owner, so owned-object queries
    /// can't find it). `wallet_id` is the Wallet object id the app already holds;
    /// `obligation_id` is the shared CurrentObligation to pass to supply/withdraw.
    public struct CurrentObligationAdopted has copy, drop {
        wallet_id: ID,
        obligation_id: ID,
        market: std::ascii::String,
    }

    const PERM_SUPPLY: u32 = 1;
    const PERM_WITHDRAW: u32 = 2;
    const PERM_BORROW: u32 = 4;
    const PERM_REPAY: u32 = 8;

    const ENotOwner: u64 = 0;
    const EWrongParent: u64 = 1;
    const ENoPerm: u64 = 2;
    const EZeroAmount: u64 = 3;

    public fun perm_supply(): u32 { PERM_SUPPLY }
    public fun perm_withdraw(): u32 { PERM_WITHDRAW }
    public fun perm_borrow(): u32 { PERM_BORROW }
    public fun perm_repay(): u32 { PERM_REPAY }
    public fun perm_all(): u32 { PERM_SUPPLY | PERM_WITHDRAW | PERM_BORROW | PERM_REPAY }

    // ===== owner setup (owner-signed) =====

    /// Open a Current obligation for `MarketT` and custody its cap in a shared,
    /// vault-parented wrapper. One-time, owner-signed. Returns the wrapper id.
    public fun adopt<MarketT>(
        sup_wallet: &Wallet,
        app: &ProtocolApp,
        market: &mut Market<MarketT>,
        ctx: &mut TxContext,
    ): ID {
        assert!(ctx.sender() == wallet::owner(sup_wallet), ENotOwner);
        let cap = enter_market::enter_market_return<MarketT>(app, market, ctx);
        let self = CurrentObligation<MarketT> {
            id: object::new(ctx),
            parent_wallet_identity: wallet::identity(sup_wallet),
            obligation_cap: cap,
            delegates: vec_map::empty(),
        };
        let id = object::id(&self);
        event::emit(CurrentObligationAdopted {
            wallet_id: object::id(sup_wallet),
            obligation_id: id,
            market: std::type_name::with_defining_ids<MarketT>().into_string(),
        });
        transfer::share_object(self);
        id
    }

    /// Grant (or replace) a delegate's permission bits. Owner-signed.
    /// `perms` = PERM_SUPPLY | PERM_WITHDRAW | PERM_BORROW | PERM_REPAY.
    public fun grant_delegate<MarketT>(
        sup_wallet: &Wallet,
        self: &mut CurrentObligation<MarketT>,
        delegate: address,
        perms: u32,
        ctx: &TxContext,
    ) {
        assert!(ctx.sender() == wallet::owner(sup_wallet), ENotOwner);
        assert_parent(sup_wallet, self);
        if (vec_map::contains(&self.delegates, &delegate)) {
            let (_, _) = vec_map::remove(&mut self.delegates, &delegate);
        };
        vec_map::insert(&mut self.delegates, delegate, perms);
    }

    /// Revoke a delegate. Owner-signed.
    public fun revoke_delegate<MarketT>(
        sup_wallet: &Wallet,
        self: &mut CurrentObligation<MarketT>,
        delegate: address,
        ctx: &TxContext,
    ) {
        assert!(ctx.sender() == wallet::owner(sup_wallet), ENotOwner);
        if (vec_map::contains(&self.delegates, &delegate)) {
            let (_, _) = vec_map::remove(&mut self.delegates, &delegate);
        };
    }

    /// Exit hatch: owner pulls the obligation cap back out and deletes the wrapper.
    #[allow(lint(self_transfer))]
    public fun reclaim<MarketT>(
        sup_wallet: &Wallet,
        self: CurrentObligation<MarketT>,
        ctx: &TxContext,
    ) {
        assert!(ctx.sender() == wallet::owner(sup_wallet), ENotOwner);
        assert_parent(sup_wallet, &self);
        let CurrentObligation { id, parent_wallet_identity: _, obligation_cap, delegates: _ } = self;
        object::delete(id);
        transfer::public_transfer(obligation_cap, ctx.sender());
    }

    // ===== Phase 1: lending (vault-funded supply / repay; withdraw to vault) =====

    /// Supply `amount` of `CoinT` from the vault into the obligation. Funded via
    /// the Sup intent (per-service + per-coin caps enforced). Gated by intent caps
    /// (the owner's authorization), not a PERM bit.
    public fun supply_from_vault<MarketT, CoinT>(
        sup_wallet: &mut Wallet,
        self: &CurrentObligation<MarketT>,
        app: &ProtocolApp,
        market: &mut Market<MarketT>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(amount > 0, EZeroAmount);
        assert_parent(sup_wallet, self);
        let tag = self.parent_wallet_identity;
        let sig = intent::request_payment<CurrentLendingAdaptor, CoinT>(CurrentLendingAdaptor {}, amount, tag);
        let (coin, ww) = intent::validate_and_pay<CurrentLendingAdaptor, CoinT>(sup_wallet, sig, ctx);
        deposit::deposit<MarketT, CoinT>(app, market, &self.obligation_cap, coin, clock, ctx);
        let receipt = intent::create_receipt_sig<CurrentLendingAdaptor, CoinT>(CurrentLendingAdaptor {}, amount, tag);
        intent::verify_and_clear<CurrentLendingAdaptor, CoinT>(ww, receipt);
    }

    /// Repay `amount` of `CoinT` debt from the vault. Funded via the Sup intent.
    /// Reduces debt (safe); gated by intent caps.
    public fun repay_from_vault<MarketT, CoinT>(
        sup_wallet: &mut Wallet,
        self: &CurrentObligation<MarketT>,
        app: &ProtocolApp,
        market: &mut Market<MarketT>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(amount > 0, EZeroAmount);
        assert_parent(sup_wallet, self);
        let tag = self.parent_wallet_identity;
        let sig = intent::request_payment<CurrentLendingAdaptor, CoinT>(CurrentLendingAdaptor {}, amount, tag);
        let (coin, ww) = intent::validate_and_pay<CurrentLendingAdaptor, CoinT>(sup_wallet, sig, ctx);
        repay::repay<MarketT, CoinT>(app, &self.obligation_cap, market, coin, clock, ctx);
        let receipt = intent::create_receipt_sig<CurrentLendingAdaptor, CoinT>(CurrentLendingAdaptor {}, amount, tag);
        intent::verify_and_clear<CurrentLendingAdaptor, CoinT>(ww, receipt);
    }

    /// Withdraw `amount` of `CoinT` collateral — ALWAYS back into the vault.
    /// Requires PERM_WITHDRAW (or the owner). Current reverts if the obligation
    /// would become unsafe.
    public fun withdraw_to_vault<MarketT, CoinT>(
        sup_wallet: &mut Wallet,
        self: &CurrentObligation<MarketT>,
        app: &ProtocolApp,
        market: &mut Market<MarketT>,
        registry: &CoinDecimalsRegistry,
        amount: u64,
        oracle: &XOracle,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(amount > 0, EZeroAmount);
        assert_parent(sup_wallet, self);
        assert_perm(sup_wallet, self, PERM_WITHDRAW, ctx);
        let coin = withdraw::withdraw_as_coin<MarketT, CoinT>(
            app, market, &self.obligation_cap, registry, amount, oracle, clock, ctx,
        );
        wallet::receive_from_service<CurrentLendingAdaptor, CoinT>(sup_wallet, coin, CurrentLendingAdaptor {});
    }

    // ===== Phase 2: borrowing (borrow to vault) =====

    /// Borrow `amount` of `CoinT` against the obligation — ALWAYS into the vault.
    /// Requires PERM_BORROW (or the owner). Takes on debt; gate the delegate with
    /// conservative caps. Current reverts if the obligation would become unsafe.
    public fun borrow_to_vault<MarketT, CoinT>(
        sup_wallet: &mut Wallet,
        self: &CurrentObligation<MarketT>,
        app: &ProtocolApp,
        market: &mut Market<MarketT>,
        registry: &CoinDecimalsRegistry,
        amount: u64,
        oracle: &XOracle,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(amount > 0, EZeroAmount);
        assert_parent(sup_wallet, self);
        assert_perm(sup_wallet, self, PERM_BORROW, ctx);
        let coin = borrow::borrow<MarketT, CoinT>(
            app, &self.obligation_cap, market, registry, amount, oracle, clock, ctx,
        );
        wallet::receive_from_service<CurrentLendingAdaptor, CoinT>(sup_wallet, coin, CurrentLendingAdaptor {});
    }

    // ===== Phase 3: Multiply / Margin building blocks =====
    // These move funds WITHIN the obligation / flash loan inside a single PTB and
    // never return funds to the caller's address. The PTB composes them with a swap
    // (the existing Cetus / swap-aggregator adaptor). See docs/current-adapter.md.

    /// Supply a coin already in the PTB (from a swap or flash loan) into the
    /// obligation. Increases collateral (safe). Requires PERM_SUPPLY.
    public fun supply_coin<MarketT, CoinT>(
        sup_wallet: &Wallet,
        self: &CurrentObligation<MarketT>,
        app: &ProtocolApp,
        market: &mut Market<MarketT>,
        coin: Coin<CoinT>,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert_parent(sup_wallet, self);
        assert_perm(sup_wallet, self, PERM_SUPPLY, ctx);
        deposit::deposit<MarketT, CoinT>(app, market, &self.obligation_cap, coin, clock, ctx);
    }

    /// Borrow and RETURN the coin to the PTB (e.g. to repay a flash loan or feed a
    /// swap). Requires PERM_BORROW. The borrowed coin must be consumed in-PTB by
    /// the composed flow — it is never transferred to an address by this adaptor.
    public fun borrow_coin<MarketT, CoinT>(
        sup_wallet: &Wallet,
        self: &CurrentObligation<MarketT>,
        app: &ProtocolApp,
        market: &mut Market<MarketT>,
        registry: &CoinDecimalsRegistry,
        amount: u64,
        oracle: &XOracle,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<CoinT> {
        assert!(amount > 0, EZeroAmount);
        assert_parent(sup_wallet, self);
        assert_perm(sup_wallet, self, PERM_BORROW, ctx);
        borrow::borrow<MarketT, CoinT>(app, &self.obligation_cap, market, registry, amount, oracle, clock, ctx)
    }

    /// Open a Current flash loan against the market. Returns the coin + the
    /// FlashLoan hot potato (must be repaid via `flash_repay` in the same PTB).
    /// Requires PERM_BORROW + a Current-granted PackageCallerCap. VERIFY: how Sup
    /// obtains/holds the caller cap.
    public fun flash_borrow<MarketT, CoinT>(
        sup_wallet: &Wallet,
        self: &CurrentObligation<MarketT>,
        app: &ProtocolApp,
        caller_cap: &PackageCallerCap,
        market: &mut Market<MarketT>,
        asset_index: u8,
        amount: u64,
        ctx: &mut TxContext,
    ): (Coin<CoinT>, FlashLoan<MarketT, CoinT>) {
        assert!(amount > 0, EZeroAmount);
        assert_parent(sup_wallet, self);
        assert_perm(sup_wallet, self, PERM_BORROW, ctx);
        flash_loan::borrow_flash_loan<MarketT, CoinT>(app, caller_cap, market, asset_index, amount, ctx)
    }

    /// Repay a Current flash loan. Ungated — the hot potato has no abilities, so the
    /// PTB must consume it here for the transaction to succeed.
    public fun flash_repay<MarketT, CoinT>(
        app: &mut ProtocolApp,
        market: &mut Market<MarketT>,
        coin: Coin<CoinT>,
        loan: FlashLoan<MarketT, CoinT>,
        ctx: &mut TxContext,
    ) {
        flash_loan::repay_flash_loan<MarketT, CoinT>(app, market, coin, loan, ctx);
    }

    // ===== reads / internal =====

    public fun parent_identity<MarketT>(self: &CurrentObligation<MarketT>): address {
        self.parent_wallet_identity
    }

    public fun has_permission<MarketT>(self: &CurrentObligation<MarketT>, who: address, perm: u32): bool {
        if (!vec_map::contains(&self.delegates, &who)) return false;
        let bits = *vec_map::get(&self.delegates, &who);
        bits & perm == perm
    }

    public fun assert_parent<MarketT>(sup_wallet: &Wallet, self: &CurrentObligation<MarketT>) {
        assert!(self.parent_wallet_identity == wallet::identity(sup_wallet), EWrongParent);
    }

    /// Owner always passes; otherwise the sender must be a delegate holding `perm`.
    fun assert_perm<MarketT>(sup_wallet: &Wallet, self: &CurrentObligation<MarketT>, perm: u32, ctx: &TxContext) {
        let sender = ctx.sender();
        if (sender == wallet::owner(sup_wallet)) return;
        assert!(has_permission(self, sender, perm), ENoPerm);
    }

    #[test_only]
    public fun not_owner_error(): u64 { ENotOwner }
    #[test_only]
    public fun wrong_parent_error(): u64 { EWrongParent }
    #[test_only]
    public fun no_perm_error(): u64 { ENoPerm }
    #[test_only]
    public fun zero_amount_error(): u64 { EZeroAmount }
}
