module SupWallet::wallet {
    use std::string::String;
    use std::type_name::{Self, TypeName};
    use sui::{
        coin::{Self, Coin},
        dynamic_field as df,
        linked_table::{Self, LinkedTable},
        object_bag::{Self, ObjectBag},
        event,
        transfer::Receiving,
    };
    use zzyzx_framework::account::{Self, Account, AccountRequest};

    const ENotYourWallet: u64 = 5;
    const EAuthServiceNotFound: u64 = 10;
    const EAuthCoinNotFound: u64 = 11;
    const EExternalAccountNotBound: u64 = 12;

    /// Wallet asset storage:
    ///
    /// - **Coins (fungible)** — held as a SIP-58 *address balance* on the
    ///   nested signer's UID. Permissionless deposits via
    ///   `sui::coin::send_funds(coin, identity(wallet))`. Owner / service
    ///   withdrawals go through `account::withdraw_funds<T>(&mut signer, amount)`
    ///   which wraps `sui::balance::withdraw_funds_from_object`. There is no
    ///   per-type `ObjectBag<Coin<T>>` entry — `coin::value` queries are RPC
    ///   (or on-chain via `balance<T>(wallet, &AccumulatorRoot)`).
    ///
    /// - **NFTs (non-fungible)** — held in `nfts: ObjectBag` keyed by a
    ///   user-provided `String`. SIP-58 doesn't apply to `key`-only objects.
    ///
    /// Ownership: `owner: address` (no transferable cap). Owner-only ops gate
    /// on `ctx.sender() == owner`.
    ///
    /// Identity: each wallet nests a `signer: Account` minted at creation. The
    /// wallet's portable identity address is `account::account_address(&signer)`.
    /// This address is **both** the AccountRequest identity (for protocols
    /// taking `&AccountRequest`) **and** the SIP-58 address-balance custody
    /// address (for `send_funds` / `withdraw_funds_from_object`).
    public struct Wallet has key, store {
        id: UID,
        owner: address,
        /// Portable identity + SIP-58 custody UID. Lifetime-bound to the
        /// wallet (minted in `create`, destroyed only if the wallet is
        /// destroyed).
        signer: Account,
        /// per-service authorization map: Service TypeName -> accepted coin TypeNames.
        auth: LinkedTable<TypeName, vector<TypeName>>,
        nfts: ObjectBag,
    }

    /// Authorization wildcard marker for "any coin type".
    /// Used only as a `TypeName` sentinel inside `auth`.
    public struct AnyCoin has drop {}

    /// Marker recorded in `CoinWithdrawn.service` for `delegation policy` spends
    /// (`pay_by_policy`). Lets indexers distinguish policy-gated delegate spends
    /// from owner-direct withdrawals (`service: None`) and per-service debits.
    public struct PolicySpend has drop {}

    public struct ExternalAccountBindingKey<phantom AccountT> has copy, drop, store {
        account: address,
    }

    public struct ServiceAssetKey<phantom ServiceT> has copy, drop, store {
        name: String,
    }

    /// ===== events =====
    /// For coin events, `service: None` means owner-direct withdrawal;
    /// `Some(ServiceTypeName)` means witness-gated service debit/credit.
    /// Direct SIP-58 deposits use `sui::coin::send_funds` and do not emit a Sup
    /// package event.

    public struct WalletCreated has copy, drop {
        wallet_id: ID,
        owner: address,
        signer_address: address,
    }

    public struct ServiceGranted has copy, drop {
        wallet_id: ID,
        service: TypeName,
        coin: TypeName,
    }

    public struct ServiceCoinRevoked has copy, drop {
        wallet_id: ID,
        service: TypeName,
        coin: TypeName,
    }

    public struct ServiceRevoked has copy, drop {
        wallet_id: ID,
        service: TypeName,
    }

    /// `new_total` is intentionally omitted — under SIP-58 the post-mutation
    /// balance lives on the accumulator and isn't cheaply readable without
    /// passing the `AccumulatorRoot`. Indexers compute it from the per-tx
    /// delta + accumulator settlement events.
    public struct CoinDeposited has copy, drop {
        wallet_id: ID,
        service: Option<TypeName>,
        coin: TypeName,
        amount: u64,
    }

    public struct CoinWithdrawn has copy, drop {
        wallet_id: ID,
        service: Option<TypeName>,
        coin: TypeName,
        amount: u64,
    }

    public struct LegacyCoinSwept has copy, drop {
        wallet_id: ID,
        coin: TypeName,
        amount: u64,
    }

    public struct AssetReclaimed has copy, drop {
        wallet_id: ID,
        asset_name: String,
    }

    /// Create a new Wallet. Sender becomes `owner`, and a fresh `Account`
    /// signer is minted and nested as the wallet's portable identity / SIP-58
    /// custody UID.
    public fun create(ctx: &mut TxContext): Wallet {
        let owner = ctx.sender();
        let signer = account::new(option::none(), ctx);
        let signer_address = account::account_address(&signer);
        let wallet = Wallet {
            id: object::new(ctx),
            owner,
            signer,
            auth: linked_table::new<TypeName, vector<TypeName>>(ctx),
            nfts: object_bag::new(ctx),
        };
        let wallet_id = object::id(&wallet);

        event::emit(WalletCreated { wallet_id, owner, signer_address });

        wallet
    }

    /// ===== auth: service -> accepted coin types =====

    public fun grant_service_coin<ServiceT, CoinT>(wallet: &mut Wallet, ctx: &TxContext) {
        assert_owner(wallet, ctx);
        let service_key = type_name::with_defining_ids<ServiceT>();
        let coin_key = type_name::with_defining_ids<CoinT>();
        add_auth(wallet, service_key, coin_key);
        event::emit(ServiceGranted { wallet_id: object::id(wallet), service: service_key, coin: coin_key });
    }

    /// Owner grants `ServiceT` permission to spend any fungible coin type.
    /// Delegate amounts are still enforced by `delegate` allowances.
    public fun grant_service_any_coin<ServiceT>(wallet: &mut Wallet, ctx: &TxContext) {
        assert_owner(wallet, ctx);
        let service_key = type_name::with_defining_ids<ServiceT>();
        let coin_key = any_coin_key();
        add_auth(wallet, service_key, coin_key);
        event::emit(ServiceGranted { wallet_id: object::id(wallet), service: service_key, coin: coin_key });
    }

    public fun revoke_service_coin<ServiceT, CoinT>(wallet: &mut Wallet, ctx: &TxContext) {
        assert_owner(wallet, ctx);
        let service_key = type_name::with_defining_ids<ServiceT>();
        let coin_key = type_name::with_defining_ids<CoinT>();
        remove_auth(wallet, service_key, coin_key);
        event::emit(ServiceCoinRevoked { wallet_id: object::id(wallet), service: service_key, coin: coin_key });
    }

    public fun revoke_service_any_coin<ServiceT>(wallet: &mut Wallet, ctx: &TxContext) {
        assert_owner(wallet, ctx);
        let service_key = type_name::with_defining_ids<ServiceT>();
        let coin_key = any_coin_key();
        remove_auth(wallet, service_key, coin_key);
        event::emit(ServiceCoinRevoked { wallet_id: object::id(wallet), service: service_key, coin: coin_key });
    }

    public fun revoke_service<ServiceT>(wallet: &mut Wallet, ctx: &TxContext) {
        assert_owner(wallet, ctx);
        let service_key = type_name::with_defining_ids<ServiceT>();
        assert!(linked_table::contains(&wallet.auth, service_key), EAuthServiceNotFound);
        let _removed = linked_table::remove(&mut wallet.auth, service_key);
        event::emit(ServiceRevoked { wallet_id: object::id(wallet), service: service_key });
    }

    /// Owner binds an external protocol account to this wallet. Official adaptors
    /// use this as the consent record for delegate-driven deposits/borrows/saves
    /// into third-party account systems such as Bucket or NAVI.
    public fun bind_external_account<AccountT>(
        wallet: &mut Wallet,
        account: address,
        ctx: &TxContext,
    ) {
        assert_owner(wallet, ctx);
        bind_external_account_internal<AccountT>(wallet, account);
    }

    /// Service-scoped binding path for adaptors that create and custody their
    /// own external account object inside the wallet.
    public fun bind_external_account_from_service<AccountT: drop>(
        wallet: &mut Wallet,
        account: address,
        _witness: AccountT,
    ) {
        bind_external_account_internal<AccountT>(wallet, account);
    }

    fun bind_external_account_internal<AccountT>(
        wallet: &mut Wallet,
        account: address,
    ) {
        let key = external_account_binding_key<AccountT>(account);
        if (!df::exists(&wallet.id, key)) {
            df::add(&mut wallet.id, key, true);
        };
    }

    public fun unbind_external_account<AccountT>(
        wallet: &mut Wallet,
        account: address,
        ctx: &TxContext,
    ) {
        assert_owner(wallet, ctx);
        let key = external_account_binding_key<AccountT>(account);
        if (df::exists(&wallet.id, key)) {
            let _removed = df::remove<ExternalAccountBindingKey<AccountT>, bool>(&mut wallet.id, key);
        };
    }

    public fun is_external_account_bound<AccountT>(wallet: &Wallet, account: address): bool {
        df::exists(&wallet.id, external_account_binding_key<AccountT>(account))
    }

    public fun assert_external_account_bound_or_owner<AccountT>(
        wallet: &Wallet,
        account: address,
        ctx: &TxContext,
    ) {
        if (!is_external_account_bound<AccountT>(wallet, account)) {
            assert!(tx_context::sender(ctx) == wallet.owner, EExternalAccountNotBound);
        };
    }

    /// Pure auth-table lookup. Owner-direct ops do NOT route through this —
    /// they verify `ctx.sender() == wallet.owner` directly via `assert_owner`.
    public fun is_authorized<ServiceT, CoinT>(wallet: &Wallet): bool {
        let service_key = type_name::with_defining_ids<ServiceT>();
        let coin_key = type_name::with_defining_ids<CoinT>();
        is_authorized_for_service(wallet, service_key, coin_key)
    }

    fun add_auth(wallet: &mut Wallet, service_key: TypeName, coin_key: TypeName) {
        if (linked_table::contains(&wallet.auth, service_key)) {
            let coins = linked_table::borrow_mut(&mut wallet.auth, service_key);
            if (!vector::contains(coins, &coin_key)) {
                vector::push_back(coins, coin_key);
            }
        } else {
            let mut coins = vector<TypeName>[];
            vector::push_back(&mut coins, coin_key);
            linked_table::push_back(&mut wallet.auth, service_key, coins);
        };
    }

    fun remove_auth(wallet: &mut Wallet, service_key: TypeName, coin_key: TypeName) {
        assert!(linked_table::contains(&wallet.auth, service_key), EAuthServiceNotFound);
        let coins = linked_table::borrow_mut(&mut wallet.auth, service_key);
        let (found, idx) = vector::index_of(coins, &coin_key);
        assert!(found, EAuthCoinNotFound);
        vector::remove(coins, idx);
    }

    fun is_authorized_for_service(wallet: &Wallet, service_key: TypeName, coin_key: TypeName): bool {
        if (!linked_table::contains(&wallet.auth, service_key)) {
            return false
        };
        let coins = linked_table::borrow(&wallet.auth, service_key);
        let wildcard_coin = any_coin_key();
        vector::contains(coins, &coin_key) || vector::contains(coins, &wildcard_coin)
    }

    fun any_coin_key(): TypeName {
        type_name::with_defining_ids<AnyCoin>()
    }

    fun external_account_binding_key<AccountT>(account: address): ExternalAccountBindingKey<AccountT> {
        ExternalAccountBindingKey<AccountT> { account }
    }

    fun service_asset_key<ServiceT>(name: String): ServiceAssetKey<ServiceT> {
        ServiceAssetKey<ServiceT> { name }
    }

    /// ===== NFT entries (String-keyed) =====

    /// add a non-coin asset to the wallet under a user-provided name.
    public fun add_asset<Asset: key + store>(wallet: &mut Wallet, asset: Asset, name: String, ctx: &TxContext) {
        assert_owner(wallet, ctx);
        object_bag::add(&mut wallet.nfts, name, asset);
    }

    /// Owner reclaims a single NFT entry by name.
    public fun reclaim_asset<Asset: key + store>(wallet: &mut Wallet, name: String, ctx: &mut TxContext) {
        assert_owner(wallet, ctx);
        let asset = object_bag::remove<String, Asset>(&mut wallet.nfts, name);
        transfer::public_transfer(asset, ctx.sender());
        event::emit(AssetReclaimed { wallet_id: object::id(wallet), asset_name: name });
    }

    /// Store a non-coin object under a service-scoped key. The service witness
    /// keeps one adaptor from reading or removing another adaptor's stored
    /// objects.
    public fun receive_asset_from_service<ServiceT: drop, Asset: key + store>(
        wallet: &mut Wallet,
        asset: Asset,
        name: String,
        _witness: ServiceT,
    ) {
        object_bag::add(&mut wallet.nfts, service_asset_key<ServiceT>(name), asset);
    }

    /// Temporarily remove a service-scoped object. Adaptors use this when an
    /// operation needs both `&mut Wallet` and a reference to a wallet-custodied
    /// external account object.
    public fun take_asset_for_service<ServiceT: drop, Asset: key + store>(
        wallet: &mut Wallet,
        name: String,
        _witness: ServiceT,
    ): Asset {
        object_bag::remove<ServiceAssetKey<ServiceT>, Asset>(
            &mut wallet.nfts,
            service_asset_key<ServiceT>(name),
        )
    }

    /// ===== coin entries (SIP-58 address balance) =====
    ///
    /// Two mutation surfaces:
    ///   - Owner-direct withdraw: `take_coin` / `withdraw_coin` — verify
    ///     `ctx.sender() == owner`
    ///   - Service-mediated debit/credit: `pay_by_service` (`public(package)`)
    ///     and `receive_from_service` — gated by
    ///     `intent` siblings which run their own auth + allowance checks
    ///     before invoking the helper.
    ///
    /// **Anyone** can deposit a coin into the wallet by calling
    /// `sui::coin::send_funds(coin, identity(wallet))` directly.

    /// Owner withdrawal to themselves.
    #[allow(lint(self_transfer))]
    public fun take_coin<CoinType>(wallet: &mut Wallet, amount: u64, ctx: &mut TxContext) {
        assert_owner(wallet, ctx);
        let coin = withdraw_internal<CoinType>(wallet, amount, option::none(), ctx);
        transfer::public_transfer(coin, ctx.sender());
    }

    /// Owner withdrawal that RETURNS the coin instead of sending it to the owner,
    /// so it can be consumed within the SAME PTB. This lets the owner, in one
    /// self-signed transaction, withdraw from the vault, use the coin in an
    /// external protocol (one with no Sup adaptor), and deposit the result back
    /// via `sui::coin::send_funds` to the wallet identity — atomically.
    /// Identical owner gate + withdrawal path as
    /// `take_coin`; only the delivery differs (returned value vs `public_transfer`),
    /// so it grants no authority `take_coin` doesn't already grant.
    public fun withdraw_coin<CoinType>(
        wallet: &mut Wallet,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<CoinType> {
        assert_owner(wallet, ctx);
        withdraw_internal<CoinType>(wallet, amount, option::none(), ctx)
    }

    /// Permissionlessly migrate a Coin that was sent to the Wallet object via
    /// the pre-SIP-58 `transfer` path into the Wallet's SIP-58 address balance.
    ///
    /// Anyone can call this for a Coin already owned by `wallet`; the received
    /// Coin is always credited to `identity(wallet)`, never to the caller.
    public fun sweep_legacy_coin<CoinType>(
        wallet: &mut Wallet,
        receiving: Receiving<Coin<CoinType>>,
    ) {
        let coin = transfer::public_receive(&mut wallet.id, receiving);
        let amount = coin::value(&coin);
        let coin_key = type_name::with_defining_ids<CoinType>();
        account::send_funds(&wallet.signer, coin);
        event::emit(CoinDeposited {
            wallet_id: object::id(wallet),
            service: option::none(),
            coin: coin_key,
            amount,
        });
        event::emit(LegacyCoinSwept {
            wallet_id: object::id(wallet),
            coin: coin_key,
            amount,
        });
    }

    /// Permissionlessly migrate a Coin that was sent to the wallet's IDENTITY
    /// (account) address via a plain `transfer`/`public_transfer` into the
    /// Wallet's SIP-58 address balance.
    ///
    /// Unlike `sweep_legacy_coin` (which receives a Coin owned by the Wallet
    /// OBJECT), this receives a Coin owned by `identity(wallet)` — the vault's
    /// keyless custody address, where funds delivered as a plain coin OBJECT to
    /// the custody address land (e.g. a legacy broker fill that used
    /// `public_transfer` instead of `send_funds`). Without this such a coin is
    /// unspendable by the intent flow (which withdraws from the address balance)
    /// AND unreachable by `sweep_legacy_coin` (wrong parent). The received Coin
    /// is always credited to `identity(wallet)`, never to the caller.
    public fun sweep_identity_coin<CoinType>(
        wallet: &mut Wallet,
        receiving: Receiving<Coin<CoinType>>,
    ) {
        let coin = account::receive(&mut wallet.signer, receiving);
        let amount = coin::value(&coin);
        let coin_key = type_name::with_defining_ids<CoinType>();
        account::send_funds(&wallet.signer, coin);
        event::emit(CoinDeposited {
            wallet_id: object::id(wallet),
            service: option::none(),
            coin: coin_key,
            amount,
        });
        event::emit(LegacyCoinSwept {
            wallet_id: object::id(wallet),
            coin: coin_key,
            amount,
        });
    }

    /// Private service-credit deposit helper. The only place that emits
    /// `CoinDeposited`.
    /// Backed by `account::send_funds` which forwards to
    /// `sui::coin::send_funds(coin, signer_address)`.
    fun deposit_internal<CoinType>(
        wallet: &Wallet,
        coin: Coin<CoinType>,
        service: Option<TypeName>,
    ) {
        let amount = coin::value(&coin);
        let coin_key = type_name::with_defining_ids<CoinType>();
        account::send_funds(&wallet.signer, coin);
        event::emit(CoinDeposited {
            wallet_id: object::id(wallet),
            service,
            coin: coin_key,
            amount,
        });
    }

    /// Private withdraw helper. The only place that emits `CoinWithdrawn`.
    /// Backed by `account::withdraw_funds` which wraps
    /// `sui::balance::withdraw_funds_from_object`.
    fun withdraw_internal<CoinType>(
        wallet: &mut Wallet,
        amount: u64,
        service: Option<TypeName>,
        ctx: &mut TxContext,
    ): Coin<CoinType> {
        let bal = account::withdraw_funds<CoinType>(&mut wallet.signer, amount);
        let coin = coin::from_balance(bal, ctx);
        event::emit(CoinWithdrawn {
            wallet_id: object::id(wallet),
            service,
            coin: type_name::with_defining_ids<CoinType>(),
            amount,
        });
        coin
    }

    /// ===== accessors =====

    public fun id(wallet: &Wallet): ID {
        object::id(wallet)
    }

    public fun owner(wallet: &Wallet): address {
        wallet.owner
    }

    /// Portable identity + SIP-58 custody address. Equals
    /// `object::id(&wallet.signer).to_address()`. Use this as:
    ///   - the recipient for third-party `sui::coin::send_funds(coin, addr)`
    ///   - the address argument for `sui::balance::settled_funds_value`
    ///   - the `.address()` of any `AccountRequest` signed by this wallet
    public fun identity(wallet: &Wallet): address {
        account::account_address(&wallet.signer)
    }

    /// Owner-gated AccountRequest issuance. Caller proves ownership via
    /// `ctx.sender`, receives an `AccountRequest` whose `.address() ==
    /// identity(wallet)`.
    public fun sign(wallet: &Wallet, ctx: &TxContext): AccountRequest {
        assert_owner(wallet, ctx);
        account::request_with_account(&wallet.signer)
    }

    /// Owner-only signer alias update.
    public fun set_signer_alias(wallet: &mut Wallet, alias: String, ctx: &TxContext) {
        assert_owner(wallet, ctx);
        account::update_alias(&mut wallet.signer, alias);
    }

    /// Owner-gate assertion. `public(package)` so sibling modules (`delegate`)
    /// can reuse it.
    public(package) fun assert_owner(wallet: &Wallet, ctx: &TxContext) {
        assert!(tx_context::sender(ctx) == wallet.owner, ENotYourWallet);
    }

    /// Read the wallet's settled balance of `CoinType` via the SIP-58
    /// accumulator. Requires the system `AccumulatorRoot` (typically `0xacc`).
    /// For off-chain readers, querying the RPC `getBalance` endpoint with
    /// `identity(wallet)` is usually more convenient.
    public fun balance<CoinType>(
        wallet: &Wallet,
        root: &sui::accumulator::AccumulatorRoot,
    ): u64 {
        account::balance_value<CoinType>(&wallet.signer, root)
    }

    public fun uid(wallet: &Wallet): &UID {
        &wallet.id
    }

    public(package) fun uid_mut(wallet: &mut Wallet): &mut UID {
        &mut wallet.id
    }

    /// Withdraw without the `is_authorized` check. ONLY callable from package
    /// siblings that perform their own access control (e.g.
    /// `intent::validate_and_pay` does auth + spender allowance debit before
    /// invoking this). The `ServiceT` tag is recorded in the emitted
    /// `CoinWithdrawn` event.
    public(package) fun pay_by_service<ServiceT, CoinType>(
        wallet: &mut Wallet,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<CoinType> {
        withdraw_internal<CoinType>(
            wallet,
            amount,
            option::some(type_name::with_defining_ids<ServiceT>()),
            ctx,
        )
    }

    /// Withdraw for a `delegation policy` spend. ONLY callable from package
    /// siblings — `SupWallet::policy::confirm_spend` invokes this after every
    /// owner-attached caveat rule has stamped the `SpendRequest` and at least one
    /// auth rule has proven the principal. No `is_authorized` / owner check here:
    /// the policy module is the access-control gate. Tagged `PolicySpend` in the
    /// emitted `CoinWithdrawn` event.
    public(package) fun pay_by_policy<CoinType>(
        wallet: &mut Wallet,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<CoinType> {
        withdraw_internal<CoinType>(
            wallet,
            amount,
            option::some(type_name::with_defining_ids<PolicySpend>()),
            ctx,
        )
    }

    /// Service-gated deposit. Lets an adaptor / service module push a
    /// `Coin<CoinType>` back into a wallet — e.g. swap output from
    /// `cetus_adaptor` after `intent::Mode D` swap-out. Witness-gated: only
    /// the module that defines `ServiceT` can construct `ServiceT{}`, so
    /// only that module can credit a wallet on its own behalf. Permissionless
    /// `sui::coin::send_funds(coin, identity(wallet))` is also fine for
    /// pure deposits with no service tag.
    public fun receive_from_service<ServiceT: drop, CoinType>(
        wallet: &Wallet,
        coin: Coin<CoinType>,
        _witness: ServiceT,
    ) {
        deposit_internal<CoinType>(
            wallet,
            coin,
            option::some(type_name::with_defining_ids<ServiceT>()),
        );
    }

    /// Package-internal version of `receive_from_service`. Used by `intent`
    /// inside Mode D `verify_swap_and_credit` where the typed
    /// `ServiceSwapReceipt<ServiceT, ...>` hot potato already proves the
    /// caller's authority — no second runtime witness needed.
    public(package) fun receive_from_service_internal<ServiceT, CoinType>(
        wallet: &Wallet,
        coin: Coin<CoinType>,
    ) {
        deposit_internal<CoinType>(
            wallet,
            coin,
            option::some(type_name::with_defining_ids<ServiceT>()),
        );
    }
}
