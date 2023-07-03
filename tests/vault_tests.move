#[test_only]
module module_addr::vault_tests {
    use std::signer;
    use std::debug;
    use std::string;

    use switchboard::aggregator;

    use aptos_framework::account;
    use aptos_framework::timestamp;
    use aptos_framework::block;
    use aptos_framework::coin;

    use aptos_std::math64;
    use aptos_std::math128;

    use module_addr::fewcha_vault;
    use module_addr::fewcha_access;
    use module_addr::fewcha_vault_price_feed;
    use module_addr::flp;

    struct BTC {}
    struct USDC {}

    fun coinPrecision(): u64 {
        math64::pow(10, 8)
    }

    fun pricePrecision(): u128 {
        math128::pow(10, 9)
    }

    fun publish_and_issue_coins(sender: &signer, lp_provider: &signer, trader: &signer) {
        aptos_framework::managed_coin::initialize<BTC>(
            sender,
            b"BTC",
            b"BTC",
            8,
            false,
        );
        aptos_framework::managed_coin::initialize<USDC>(
            sender,
            b"USDC",
            b"USDC",
            8,
            false,
        );

        // Issue to lp_provider (BTC)
        let receiver_addr = signer::address_of(lp_provider);
        aptos_framework::managed_coin::register<BTC>(lp_provider);
        aptos_framework::managed_coin::mint<BTC>(
            sender,
            receiver_addr,
            1000 * coinPrecision(),
        );

        aptos_framework::managed_coin::register<USDC>(lp_provider);
        aptos_framework::managed_coin::mint<USDC>(
            sender,
            receiver_addr,
            1000 * coinPrecision(),
        );

        debug::print(&string::utf8(b"[INIT] LP has 1000 USDC, 1000 BTC"));

        // Issue to trader (USDC)
        let receiver_addr = signer::address_of(trader);
        aptos_framework::managed_coin::register<USDC>(trader);
        aptos_framework::managed_coin::mint<USDC>(
            sender,
            receiver_addr,
            1000 * coinPrecision(),
        );

        debug::print(&string::utf8(b"[INIT] Trader has 1000 USDC"));
    }

    fun init_modules(sender: &signer) {
        fewcha_access::test_init_module(sender);
        fewcha_vault::test_init_module(sender);
        fewcha_vault_price_feed::test_init_module(sender);
    }

    fun setup_aggregator(sender: &signer, usdc_aggregator: &signer, btc_aggregator: &signer) {
        aggregator::new_test(
            usdc_aggregator, 
            1 * pricePrecision(), // $1
            9, // dec
            false
        );
        fewcha_vault_price_feed::update_aggregator<USDC>(sender, signer::address_of(usdc_aggregator));

        aggregator::new_test(
            btc_aggregator, 
            20 * pricePrecision(), // $20
            9, // dec
            false
        );
        fewcha_vault_price_feed::update_aggregator<BTC>(sender, signer::address_of(btc_aggregator));
    }

    fun init_test(
        aptos_framework: &signer,

        gov: &signer, 
        lp_provider: &signer, 
        trader: &signer,

        usdc_aggregator: &signer, 
        btc_aggregator: &signer,
    ) {
        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(gov));
        account::create_account_for_test(signer::address_of(lp_provider));
        account::create_account_for_test(signer::address_of(trader));

        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test(1);
        block::initialize_for_test(aptos_framework, 1);

        publish_and_issue_coins(gov, lp_provider, trader);
        init_modules(gov);

        setup_aggregator(gov, usdc_aggregator, btc_aggregator);
        
        // 1. GOV Whitelist coins - Set no fee
        fewcha_vault::set_coin_config<USDC>(
            gov,
            500, // weight: u64,
            0, // min_profit_bps: u128,
            0, // max_lp_amount: u128,
            true, // is_whitelist: bool,
            true, // is_stable: bool,
            false, // is_shortable: bool
        );

        fewcha_vault::set_coin_config<BTC>(
            gov,
            500,
            0,
            0,
            true,
            false,
            true
        );

        fewcha_vault::set_fees(
            gov,
            0, // tax_basis_points: u128,
            0, // stable_tax_basis_points: u128,
            0, // mint_burn_fee_basis_points: u128,
            0, // swap_fee_basis_points: u128,
            0, // stable_swap_fee_basis_points: u128,
            false // has_dynamic_fees: bool
        );

        // 2. LP add some coin to pool
        let lp_provider_addr = signer::address_of(lp_provider);
        fewcha_vault::add_liquidity<BTC>(
            lp_provider,
            10 * (coinPrecision() as u128),
        );
        let flp_balance = coin::balance<flp::FLP>(lp_provider_addr);
        assert!(flp_balance == 200 * coinPrecision(), 1);

        fewcha_vault::add_liquidity<USDC>(
            lp_provider,
            200 * (coinPrecision() as u128),
        );
        let flp_balance = coin::balance<flp::FLP>(lp_provider_addr);
        assert!(flp_balance == 400 * coinPrecision(), 2);

        debug::print(&string::utf8(b"[INIT] LP has 200 USDC - 10 BTC"));
    }

    #[test(
        aptos_framework = @aptos_framework,

        gov = @module_addr,
        lp_provider = @0x100,
        trader = @0x101,

        usdc_aggregator = @0x200,
        btc_aggregator = @0x201,
    )]
    fun test_remove_lp_success(
        aptos_framework: &signer,

        gov: &signer, 
        lp_provider: &signer, 
        trader: &signer,

        usdc_aggregator: &signer, 
        btc_aggregator: &signer,
    ) {
        init_test(
            aptos_framework,

            gov, 
            lp_provider, 
            trader,

            usdc_aggregator, 
            btc_aggregator,
        );

        debug::print(&string::utf8(b"[Remove LP] 1. LP remove 100 USDC from pool"));
        let lp_provider_addr = signer::address_of(lp_provider);
        fewcha_vault::remove_liquidity<USDC>(
            lp_provider,
            100 * (coinPrecision() as u128),
        );

        let flp_balance = coin::balance<flp::FLP>(lp_provider_addr);
        assert!(flp_balance == 300 * coinPrecision(), 1);
        let usdc_balance = coin::balance<USDC>(lp_provider_addr);
        assert!(usdc_balance == 900 * coinPrecision(), 2);
    }

    #[test(
        aptos_framework = @aptos_framework,

        gov = @module_addr,
        lp_provider = @0x100,
        trader = @0x101,

        usdc_aggregator = @0x200,
        btc_aggregator = @0x201,
    )]
    fun test_swap_success(
        aptos_framework: &signer,

        gov: &signer, 
        lp_provider: &signer, 
        trader: &signer,

        usdc_aggregator: &signer, 
        btc_aggregator: &signer,
    ) {
        init_test(
            aptos_framework,

            gov, 
            lp_provider, 
            trader,

            usdc_aggregator, 
            btc_aggregator,
        );

        debug::print(&string::utf8(b"[SWAP] 1. Trader want to swap 40 USDC -> 2 BTC"));
        let trader_addr = signer::address_of(trader);
        fewcha_vault::swap<USDC, BTC> (
            trader,
            40 * (coinPrecision() as u128),
        );
        let btc_balance = coin::balance<BTC>(trader_addr);
        assert!(btc_balance == 2 * coinPrecision(), 1);
        let usdc_balance = coin::balance<USDC>(trader_addr);
        assert!(usdc_balance == 960 * coinPrecision(), 2);

        debug::print(&string::utf8(b"[SWAP] 2. Trader want to swap 1 BTC -> 20 USDC"));
        let trader_addr = signer::address_of(trader);
        fewcha_vault::swap<BTC, USDC> (
            trader,
            1 * (coinPrecision() as u128),
        );
        let btc_balance = coin::balance<BTC>(trader_addr);
        assert!(btc_balance == 1 * coinPrecision(), 3);
        let usdc_balance = coin::balance<USDC>(trader_addr);
        assert!(usdc_balance == 980 * coinPrecision(), 4);
    }
    

    #[test(
        aptos_framework = @aptos_framework,

        gov = @module_addr,
        lp_provider = @0x100,
        trader = @0x101,

        usdc_aggregator = @0x200,
        btc_aggregator = @0x201,
    )]
    fun test_margin_success(
        aptos_framework: &signer,

        gov: &signer, 
        lp_provider: &signer, 
        trader: &signer,

        usdc_aggregator: &signer, 
        btc_aggregator: &signer,
    ) {
        init_test(
            aptos_framework,

            gov, 
            lp_provider, 
            trader,

            usdc_aggregator, 
            btc_aggregator,
        );

        debug::print(&string::utf8(b"[MARGIN] 1. LP provider want to increase long position: 2 BTC x5 = 10 BTC"));
        let trader_addr = signer::address_of(trader);
        fewcha_vault::increase_long_position<BTC> (
            lp_provider,
            2 * (coinPrecision() as u128),
            10 * (coinPrecision() as u128),
        );
        let btc_balance = coin::balance<BTC>(trader_addr);
        assert!(btc_balance == 998 * coinPrecision(), 1);

        debug::print(&string::utf8(b"[MARGIN] 2. BTC price increase x2=$40 - 1 hour later"));
        timestamp::fast_forward_seconds(3600); // 1 hour later
        aggregator::new_test(
            btc_aggregator, 
            40 * pricePrecision(), // $40
            9, // dec
            false
        );
    }
}