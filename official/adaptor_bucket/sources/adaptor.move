module adaptor_bucket::adaptor;

use std::string::String;
use SupWallet::delegate;
use SupWallet::intent;
use SupWallet::wallet::{Self, Wallet};
use bucket_cdp::vault::{Self, Vault};
use bucket_framework::account::{Self, Account};
use bucket_oracle::result::PriceResult;
use bucket_saving::saving::{Self, SavingPool};
use bucket_saving_incentive::incentive_config::GlobalConfig as IncentiveConfig;
use bucket_saving_incentive::saving_incentive::{Self, RewardManager};
use bucket_usdb::usdb::{Treasury, USDB};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;

const EZeroAmount: u64 = 0;
const EAccountMismatch: u64 = 1;
const EInsufficientOutput: u64 = 2;
const ENotAuthorized: u64 = 3;

public struct BucketAdaptor has drop {}

public struct BucketBorrowed has copy, drop {
    account: address,
    collateral_in: u64,
    usdb_out: u64,
}

public struct BucketSavingDeposited has copy, drop {
    account: address,
    usdb_in: u64,
}

public struct BucketSavingWithdrawn has copy, drop {
    account: address,
    usdb_out: u64,
}

public struct BucketRepaidWithdrawn has copy, drop {
    account: address,
    usdb_repaid: u64,
    collateral_out: u64,
}

public struct BucketAccountCreated has copy, drop {
    wallet_id: ID,
    account: address,
}

public struct BucketAccountReclaimed has copy, drop {
    wallet_id: ID,
    account: address,
}

public fun create_bucket_account(
    wallet: &mut Wallet,
    name: Option<String>,
    ctx: &mut TxContext,
): address {
    assert_bucket_operator(wallet, ctx);
    let account = account::new(name, ctx);
    let account_address = account::account_address(&account);
    wallet::bind_external_account_from_service<BucketAdaptor>(
        wallet,
        account_address,
        BucketAdaptor {},
    );
    put_bucket_account(wallet, account);
    event::emit(BucketAccountCreated {
        wallet_id: wallet::id(wallet),
        account: account_address,
    });
    account_address
}

public fun reclaim_bucket_account(wallet: &mut Wallet, ctx: &mut TxContext): Account {
    assert!(ctx.sender() == wallet::owner(wallet), ENotAuthorized);
    let account = take_bucket_account(wallet);
    let account_address = account::account_address(&account);
    event::emit(BucketAccountReclaimed {
        wallet_id: wallet::id(wallet),
        account: account_address,
    });
    account
}

public fun borrow_usdb_with_stored_account<Collateral>(
    wallet: &mut Wallet,
    vault: &mut Vault<Collateral>,
    treasury: &mut Treasury,
    price: &Option<PriceResult<Collateral>>,
    collateral_amount: u64,
    borrow_amount: u64,
    min_usdb_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let account = take_bucket_account(wallet);
    let expected_account = account::account_address(&account);
    borrow_usdb<Collateral>(
        wallet,
        &account,
        expected_account,
        vault,
        treasury,
        price,
        collateral_amount,
        borrow_amount,
        min_usdb_out,
        clock,
        ctx,
    );
    put_bucket_account(wallet, account);
}

public fun borrow_usdb_from_stored_position<Collateral>(
    wallet: &mut Wallet,
    vault: &mut Vault<Collateral>,
    treasury: &mut Treasury,
    price: &Option<PriceResult<Collateral>>,
    borrow_amount: u64,
    min_usdb_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_bucket_operator(wallet, ctx);
    let account = take_bucket_account(wallet);
    let expected_account = account::account_address(&account);
    borrow_usdb_from_position<Collateral>(
        wallet,
        &account,
        expected_account,
        vault,
        treasury,
        price,
        borrow_amount,
        min_usdb_out,
        clock,
        ctx,
    );
    put_bucket_account(wallet, account);
}

public fun save_usdb_with_stored_account<LP>(
    wallet: &mut Wallet,
    pool: &mut SavingPool<LP>,
    treasury: &mut Treasury,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let account = take_bucket_account(wallet);
    let expected_account = account::account_address(&account);
    save_usdb<LP>(
        wallet,
        &account,
        expected_account,
        pool,
        treasury,
        amount,
        clock,
        ctx,
    );
    put_bucket_account(wallet, account);
}

public fun save_usdb_with_stored_account_and_incentive<LP, Reward>(
    wallet: &mut Wallet,
    pool: &mut SavingPool<LP>,
    treasury: &mut Treasury,
    incentive_config: &IncentiveConfig,
    reward_manager: &mut RewardManager<LP>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let account = take_bucket_account(wallet);
    let expected_account = account::account_address(&account);
    save_usdb_with_incentive<LP, Reward>(
        wallet,
        &account,
        expected_account,
        pool,
        treasury,
        incentive_config,
        reward_manager,
        amount,
        clock,
        ctx,
    );
    put_bucket_account(wallet, account);
}

public fun withdraw_saving_with_stored_account<LP>(
    wallet: &mut Wallet,
    pool: &mut SavingPool<LP>,
    treasury: &mut Treasury,
    amount: u64,
    min_usdb_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_bucket_operator(wallet, ctx);
    let account = take_bucket_account(wallet);
    let expected_account = account::account_address(&account);
    withdraw_saving<LP>(
        wallet,
        &account,
        expected_account,
        pool,
        treasury,
        amount,
        min_usdb_out,
        clock,
        ctx,
    );
    put_bucket_account(wallet, account);
}

public fun withdraw_saving_with_stored_account_and_incentive<LP, Reward>(
    wallet: &mut Wallet,
    pool: &mut SavingPool<LP>,
    treasury: &mut Treasury,
    incentive_config: &IncentiveConfig,
    reward_manager: &mut RewardManager<LP>,
    amount: u64,
    min_usdb_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_bucket_operator(wallet, ctx);
    let account = take_bucket_account(wallet);
    let expected_account = account::account_address(&account);
    withdraw_saving_with_incentive<LP, Reward>(
        wallet,
        &account,
        expected_account,
        pool,
        treasury,
        incentive_config,
        reward_manager,
        amount,
        min_usdb_out,
        clock,
        ctx,
    );
    put_bucket_account(wallet, account);
}

public fun borrow_usdb<Collateral>(
    wallet: &mut Wallet,
    bucket_account: &Account,
    expected_account: address,
    vault: &mut Vault<Collateral>,
    treasury: &mut Treasury,
    price: &Option<PriceResult<Collateral>>,
    collateral_amount: u64,
    borrow_amount: u64,
    min_usdb_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(borrow_amount > 0, EZeroAmount);
    assert_account(bucket_account, expected_account);
    wallet::assert_external_account_bound_or_owner<BucketAdaptor>(
        wallet,
        expected_account,
        ctx,
    );

    let sig = intent::request_swap<BucketAdaptor, Collateral, USDB>(
        BucketAdaptor {},
        collateral_amount,
        min_usdb_out,
    );
    let (collateral, wallet_swap_witness) =
        intent::validate_and_swap_out<BucketAdaptor, Collateral, USDB>(
            wallet,
            sig,
            ctx,
        );

    let account_request = account::request_with_account(bucket_account);
    let repay_coin = coin::zero<USDB>(ctx);
    let request = vault::debtor_request<Collateral>(
        vault,
        &account_request,
        treasury,
        collateral,
        borrow_amount,
        repay_coin,
        0,
    );
    let (collateral_out, usdb_out, response) = vault::update_position<Collateral>(
        vault,
        treasury,
        clock,
        price,
        request,
        ctx,
    );
    vault::destroy_response<Collateral>(vault, treasury, response);

    let usdb_amount = coin::value(&usdb_out);
    let receipt = intent::create_swap_receipt<BucketAdaptor, Collateral, USDB>(
        BucketAdaptor {},
        collateral_amount,
        usdb_amount,
    );
    intent::verify_swap_and_credit<BucketAdaptor, Collateral, USDB>(
        wallet,
        wallet_swap_witness,
        receipt,
        usdb_out,
    );
    credit_or_destroy_coin<BucketAdaptor, Collateral>(wallet, collateral_out, BucketAdaptor {});

    event::emit(BucketBorrowed {
        account: expected_account,
        collateral_in: collateral_amount,
        usdb_out: usdb_amount,
    });
}

public fun borrow_usdb_from_position<Collateral>(
    wallet: &mut Wallet,
    bucket_account: &Account,
    expected_account: address,
    vault: &mut Vault<Collateral>,
    treasury: &mut Treasury,
    price: &Option<PriceResult<Collateral>>,
    borrow_amount: u64,
    min_usdb_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(borrow_amount > 0, EZeroAmount);
    assert_account(bucket_account, expected_account);
    wallet::assert_external_account_bound_or_owner<BucketAdaptor>(
        wallet,
        expected_account,
        ctx,
    );

    let account_request = account::request_with_account(bucket_account);
    let collateral = coin::zero<Collateral>(ctx);
    let repay_coin = coin::zero<USDB>(ctx);
    let request = vault::debtor_request<Collateral>(
        vault,
        &account_request,
        treasury,
        collateral,
        borrow_amount,
        repay_coin,
        0,
    );
    let (collateral_out, usdb_out, response) = vault::update_position<Collateral>(
        vault,
        treasury,
        clock,
        price,
        request,
        ctx,
    );
    vault::destroy_response<Collateral>(vault, treasury, response);

    let usdb_amount = coin::value(&usdb_out);
    assert!(usdb_amount >= min_usdb_out, EInsufficientOutput);
    wallet::receive_from_service<BucketAdaptor, USDB>(wallet, usdb_out, BucketAdaptor {});
    credit_or_destroy_coin<BucketAdaptor, Collateral>(wallet, collateral_out, BucketAdaptor {});

    event::emit(BucketBorrowed {
        account: expected_account,
        collateral_in: 0,
        usdb_out: usdb_amount,
    });
}

/// Repay USDB and withdraw collateral in one no-sign call. The USDB to repay is
/// pulled from the vault (bounded by the adaptor allowance); the withdrawn
/// collateral — and any USDB refund from an over-repay — are credited straight
/// BACK TO THE VAULT, never to the caller/agent. The owner then withdraws the
/// collateral from the vault with their own key.
public fun repay_and_withdraw<Collateral>(
    wallet: &mut Wallet,
    bucket_account: &Account,
    expected_account: address,
    vault: &mut Vault<Collateral>,
    treasury: &mut Treasury,
    price: &Option<PriceResult<Collateral>>,
    repay_amount: u64,
    withdraw_amount: u64,
    min_collateral_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(repay_amount > 0, EZeroAmount);
    assert_account(bucket_account, expected_account);
    wallet::assert_external_account_bound_or_owner<BucketAdaptor>(
        wallet,
        expected_account,
        ctx,
    );

    // Pull the USDB to repay from the vault (allowance-bounded payment intent).
    let sig = intent::request_payment<BucketAdaptor, USDB>(
        BucketAdaptor {},
        repay_amount,
        expected_account,
    );
    let (repay_coin, wallet_witness) =
        intent::validate_and_pay<BucketAdaptor, USDB>(wallet, sig, ctx);

    let account_request = account::request_with_account(bucket_account);
    let collateral_in = coin::zero<Collateral>(ctx);
    let request = vault::debtor_request<Collateral>(
        vault,
        &account_request,
        treasury,
        collateral_in,
        0,
        repay_coin,
        withdraw_amount,
    );
    let (collateral_out, usdb_out, response) = vault::update_position<Collateral>(
        vault,
        treasury,
        clock,
        price,
        request,
        ctx,
    );
    vault::destroy_response<Collateral>(vault, treasury, response);

    let receipt = intent::create_receipt_sig<BucketAdaptor, USDB>(
        BucketAdaptor {},
        repay_amount,
        expected_account,
    );
    intent::verify_and_clear<BucketAdaptor, USDB>(wallet_witness, receipt);

    let collateral_amount = coin::value(&collateral_out);
    assert!(collateral_amount >= min_collateral_out, EInsufficientOutput);

    // Custody: withdrawn collateral + any over-repay USDB refund go back to the vault.
    credit_or_destroy_coin<BucketAdaptor, Collateral>(wallet, collateral_out, BucketAdaptor {});
    credit_or_destroy_coin<BucketAdaptor, USDB>(wallet, usdb_out, BucketAdaptor {});

    event::emit(BucketRepaidWithdrawn {
        account: expected_account,
        usdb_repaid: repay_amount,
        collateral_out: collateral_amount,
    });
}

public fun save_usdb<LP>(
    wallet: &mut Wallet,
    bucket_account: &Account,
    expected_account: address,
    pool: &mut SavingPool<LP>,
    treasury: &mut Treasury,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(amount > 0, EZeroAmount);
    assert_account(bucket_account, expected_account);
    wallet::assert_external_account_bound_or_owner<BucketAdaptor>(
        wallet,
        expected_account,
        ctx,
    );

    let sig = intent::request_payment<BucketAdaptor, USDB>(
        BucketAdaptor {},
        amount,
        expected_account,
    );
    let (usdb, wallet_witness) =
        intent::validate_and_pay<BucketAdaptor, USDB>(wallet, sig, ctx);
    let response = saving::deposit<LP>(
        pool,
        treasury,
        expected_account,
        usdb,
        clock,
        ctx,
    );
    let deposited = saving::deposit_response_deposited_usdb_amount<LP>(&response);
    let receipt = intent::create_receipt_sig<BucketAdaptor, USDB>(
        BucketAdaptor {},
        amount,
        expected_account,
    );
    intent::verify_and_clear<BucketAdaptor, USDB>(wallet_witness, receipt);
    saving::check_deposit_response<LP>(response, pool, treasury);

    event::emit(BucketSavingDeposited {
        account: expected_account,
        usdb_in: deposited,
    });
}

public fun save_usdb_with_incentive<LP, Reward>(
    wallet: &mut Wallet,
    bucket_account: &Account,
    expected_account: address,
    pool: &mut SavingPool<LP>,
    treasury: &mut Treasury,
    incentive_config: &IncentiveConfig,
    reward_manager: &mut RewardManager<LP>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(amount > 0, EZeroAmount);
    assert_account(bucket_account, expected_account);
    wallet::assert_external_account_bound_or_owner<BucketAdaptor>(
        wallet,
        expected_account,
        ctx,
    );

    let sig = intent::request_payment<BucketAdaptor, USDB>(
        BucketAdaptor {},
        amount,
        expected_account,
    );
    let (usdb, wallet_witness) =
        intent::validate_and_pay<BucketAdaptor, USDB>(wallet, sig, ctx);
    let response = saving::deposit<LP>(
        pool,
        treasury,
        expected_account,
        usdb,
        clock,
        ctx,
    );
    let deposited = saving::deposit_response_deposited_usdb_amount<LP>(&response);
    let mut checker = saving_incentive::new_checker_for_deposit_action<LP>(
        reward_manager,
        incentive_config,
        response,
    );
    saving_incentive::update_deposit_action<LP, Reward>(
        &mut checker,
        incentive_config,
        reward_manager,
        pool,
        clock,
    );
    let response = saving_incentive::destroy_deposit_checker<LP>(checker, incentive_config);
    let receipt = intent::create_receipt_sig<BucketAdaptor, USDB>(
        BucketAdaptor {},
        amount,
        expected_account,
    );
    intent::verify_and_clear<BucketAdaptor, USDB>(wallet_witness, receipt);
    saving::check_deposit_response<LP>(response, pool, treasury);

    event::emit(BucketSavingDeposited {
        account: expected_account,
        usdb_in: deposited,
    });
}

public fun withdraw_saving<LP>(
    wallet: &mut Wallet,
    bucket_account: &Account,
    expected_account: address,
    pool: &mut SavingPool<LP>,
    treasury: &mut Treasury,
    amount: u64,
    min_usdb_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(amount > 0, EZeroAmount);
    assert_account(bucket_account, expected_account);
    wallet::assert_external_account_bound_or_owner<BucketAdaptor>(
        wallet,
        expected_account,
        ctx,
    );

    let account_request = account::request_with_account(bucket_account);
    let (usdb, response) = saving::withdraw<LP>(
        pool,
        treasury,
        &account_request,
        amount,
        clock,
        ctx,
    );
    let usdb_amount = coin::value(&usdb);
    assert!(usdb_amount >= min_usdb_out, EInsufficientOutput);
    saving::check_withdraw_response<LP>(response, pool, treasury);
    wallet::receive_from_service<BucketAdaptor, USDB>(wallet, usdb, BucketAdaptor {});

    event::emit(BucketSavingWithdrawn {
        account: expected_account,
        usdb_out: usdb_amount,
    });
}

public fun withdraw_saving_with_incentive<LP, Reward>(
    wallet: &mut Wallet,
    bucket_account: &Account,
    expected_account: address,
    pool: &mut SavingPool<LP>,
    treasury: &mut Treasury,
    incentive_config: &IncentiveConfig,
    reward_manager: &mut RewardManager<LP>,
    amount: u64,
    min_usdb_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(amount > 0, EZeroAmount);
    assert_account(bucket_account, expected_account);
    wallet::assert_external_account_bound_or_owner<BucketAdaptor>(
        wallet,
        expected_account,
        ctx,
    );

    let account_request = account::request_with_account(bucket_account);
    let (usdb, response) = saving::withdraw<LP>(
        pool,
        treasury,
        &account_request,
        amount,
        clock,
        ctx,
    );
    let usdb_amount = coin::value(&usdb);
    assert!(usdb_amount >= min_usdb_out, EInsufficientOutput);
    let mut checker = saving_incentive::new_checker_for_withdraw_action<LP>(
        reward_manager,
        incentive_config,
        response,
    );
    saving_incentive::update_withdraw_action<LP, Reward>(
        &mut checker,
        incentive_config,
        reward_manager,
        pool,
        clock,
    );
    let response = saving_incentive::destroy_withdraw_checker<LP>(checker, incentive_config);
    saving::check_withdraw_response<LP>(response, pool, treasury);
    wallet::receive_from_service<BucketAdaptor, USDB>(wallet, usdb, BucketAdaptor {});

    event::emit(BucketSavingWithdrawn {
        account: expected_account,
        usdb_out: usdb_amount,
    });
}

fun assert_account(account: &Account, expected: address) {
    assert!(account::account_address(account) == expected, EAccountMismatch);
}

fun assert_bucket_operator(wallet: &Wallet, ctx: &TxContext) {
    let sender = ctx.sender();
    if (sender == wallet::owner(wallet)) return;
    assert!(delegate::service_allowance<BucketAdaptor>(wallet, sender) > 0, ENotAuthorized);
}

fun bucket_account_name(): String {
    b"bucket_account".to_string()
}

fun take_bucket_account(wallet: &mut Wallet): Account {
    wallet::take_asset_for_service<BucketAdaptor, Account>(
        wallet,
        bucket_account_name(),
        BucketAdaptor {},
    )
}

fun put_bucket_account(wallet: &mut Wallet, account: Account) {
    wallet::receive_asset_from_service<BucketAdaptor, Account>(
        wallet,
        account,
        bucket_account_name(),
        BucketAdaptor {},
    );
}

fun credit_or_destroy_coin<ServiceT: drop, CoinT>(
    wallet: &Wallet,
    coin: Coin<CoinT>,
    witness: ServiceT,
) {
    if (coin::value(&coin) == 0) {
        coin::destroy_zero(coin);
    } else {
        wallet::receive_from_service<ServiceT, CoinT>(wallet, coin, witness);
    }
}
