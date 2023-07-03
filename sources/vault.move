module module_addr::fewcha_vault {
    use std::string;
    use std::signer;
    use std::error;
    use std::hash;
    use std::bcs;
    use std::vector;
    use std::option;

    use aptos_std::event::{Self, EventHandle};
    use aptos_std::table::{Self, Table};
    use aptos_std::type_info;
    use aptos_std::math128;

    use aptos_framework::coin;
    use aptos_framework::account;
    use aptos_framework::timestamp;

    use module_addr::fewcha_vault_price_feed;
    use module_addr::flp::{Self, FLP};
    use module_addr::fewcha_access;
    use module_addr::managed_coin;

    struct CoinConfig has copy, drop, store {
        weight: u64,
        min_profit_bps: u128,
        max_lp_amount: u128,
        is_whitelist: bool,
        is_stable: bool,
        is_shortable: bool
    }

    struct Position has drop, store {
        size: u128,
        collateral: u128,
        average_price: u128,
        entry_funding_rate: u64,
        reserve_amount: u128,
        realised_pnl: u128,
        last_increased_time: u64
    }

    struct VaultStore has key {
        signer_cap: account::SignerCapability,
        total_coin_weights: u64,
    }

    struct VaultFundStore has key {
        funding_interval: u64,
        funding_rate_factor: u64,
        stable_funding_rate_factor: u64,
    }

    struct VaultTradingStore has key {
        positions: Table<vector<u8>, Position>, // PositonID => Position
        trading_fee: u128,
    }

    struct VaultCoinStore<phantom CoinType> has key {

        config: CoinConfig,

        // Pool
        pool_amount: u128, // Coin Amount
        lp_amount: u128, // LP Amount

        // Fund
        cumulative_funding_rate: u128, // Cumulative funding rate
        last_funding_time: u64, // Last funding times

        // Trading
        reserved_amount: u128, // Reserved Amount

        //// Long
        guaranteed_usd: u128, // Guaranteed USD Amount

        //// Short
        short_size: u128, // Global Short size
        max_short_size: u128, // Max Global Short size
        short_average_price: u128, // Global Short average price

        // Fee
        fee_reserve: u128, // Fee Reserved Amount
    }

    struct VaultFeeStore has key {
        has_dynamic_fees: bool,
        tax_basis_points: u128,
        stable_tax_basis_points: u128,
        mint_burn_fee_basis_points: u128,
        swap_fee_basis_points: u128,
        stable_swap_fee_basis_points: u128,
    }

    ///////////////////////////////
    /// CONSTANTS
    ///////////////////////////////
    const BASIS_POINTS_DIVISOR: u128 = 10000;
    const FUNDING_RATE_PRECISION: u128 = 1000000;
    const MAX_FEE_BASIS_POINTS: u128 = 500; // 5%

    // FEE
    const MIN_PROFIT_TIME: u64 = 0; // 0s

    ///////////////////////////////
    /// EVENTS
    ///////////////////////////////
    struct AddLiquidity has drop, store {
        lp_provider: address,
        coin_type: string::String,
        amount: u128,
        lp_amount: u128,
        fee_basis_points: u128
    }

    struct RemoveLiquidity has drop, store {
        lp_provider: address,
        coin_type: string::String,
        amount: u128,
        lp_amount: u128,
        fee_basis_points: u128,
    }

    struct Swap has drop, store {
        sender_addr: address,
        coin_type_in: string::String,
        coin_type_out: string::String,
        amount_in: u128,
        amount_out: u128,
        token_amount_out_after_fees: u128,
        fee_basis_points: u128,
    }
    
    struct DirectPoolDeposit has drop, store {
        lp_provider: address,
        coin_type: string::String,
        amount: u128,
    }

    struct IncreasePoolAmount has drop, store {
        coin_type: string::String,
        amount: u128,
    }

    struct IncreaseLpAmount has drop, store {
        coin_type: string::String,
        amount: u128,
    }

    struct DecreasePoolAmount has drop, store {
        coin_type: string::String,
        amount: u128,
    }

    struct DecreaseLpAmount has drop, store {
        coin_type: string::String,
        amount: u128,
    }

    struct IncreaseReservedAmount has drop, store {
        coin_type: string::String,
        amount: u128,
    }

    struct DecreaseReservedAmount has drop, store {
        coin_type: string::String,
        amount: u128,
    }

    struct CollectMarginFees has drop, store {
        coin_type: string::String,
        fee_usd: u128,
        fee_coin_amount: u128
    }

    struct CollectSwapFees has drop, store {
        coin_type: string::String,
        fee_usd: u128,
        fee_coin_amount: u128
    }

    struct IncreaseLongPosition has drop, store {
        position_key: vector<u8>,
        sender_addr: address,
        coin_type: string::String,
        collateral_delta_usd: u128,
        size_delta: u128,
        price: u128,
        fee_usd: u128
    }

    struct DecreaseLongPosition has drop, store {
        position_key: vector<u8>,
        sender_addr: address,
        coin_type: string::String,
        collateral_delta_usd: u128,
        size_delta: u128,
        price: u128,
        fee_usd: u128
    }

    struct IncreaseShortPosition has drop, store {
        position_key: vector<u8>,
        sender_addr: address,
        coin_type_collateral: string::String,
        coin_type_index: string::String,
        collateral_delta_usd: u128,
        size_delta: u128,
        price: u128,
        fee_usd: u128
    }

    struct DecreaseShortPosition has drop, store {
        position_key: vector<u8>,
        sender_addr: address,
        coin_type_collateral: string::String,
        coin_type_index: string::String,
        collateral_delta_usd: u128,
        size_delta: u128,
        price: u128,
        fee_usd: u128
    }

    struct UpdatePosition has drop, store {
        position_key: vector<u8>,
        size: u128,
        collateral: u128,
        average_price: u128,
        entry_funding_rate: u64,
        reserve_amount: u128,
        realised_pnl: u128,
        price: u128
    }

    struct ClosePosition has drop, store {
        position_key: vector<u8>,
        size: u128,
        collateral: u128,
        average_price: u128,
        entry_funding_rate: u64,
        reserve_amount: u128,
        realised_pnl: u128,
    }
    
    struct IncreaseGuaranteedUsd has drop, store {
        coin_type: string::String,
        usd_amount: u128,
    }

    struct DecreaseGuaranteedUsd has drop, store {
        coin_type: string::String,
        usd_amount: u128,
    }

    struct UpdateFundingRate has drop, store {
        coin_type: string::String,
        cumulative_funding_rate: u128,
    }

    struct UpdatePnl has drop, store {
        position_key: vector<u8>,
        has_profit: bool,
        adjusted_delta: u128,
    }

    struct VaultEvents has key {
        add_liquidity: EventHandle<AddLiquidity>,
        remove_liquidity: EventHandle<RemoveLiquidity>,
        direct_pool_deposit: EventHandle<DirectPoolDeposit>,
        swap: EventHandle<Swap>,
        increase_pool_amount: EventHandle<IncreasePoolAmount>,
        increase_lp_amount: EventHandle<IncreaseLpAmount>,
        decrease_pool_amount: EventHandle<DecreasePoolAmount>,
        decrease_lp_amount: EventHandle<DecreaseLpAmount>,
        increase_reserved_amount: EventHandle<IncreaseReservedAmount>,
        decrease_reserved_amount: EventHandle<DecreaseReservedAmount>,
        collect_margin_fees: EventHandle<CollectMarginFees>,
        collect_swap_fees: EventHandle<CollectSwapFees>,
        increase_long_position: EventHandle<IncreaseLongPosition>,
        increase_short_position: EventHandle<IncreaseShortPosition>,
        decrease_long_position: EventHandle<DecreaseLongPosition>,
        decrease_short_position: EventHandle<DecreaseShortPosition>,
        update_position: EventHandle<UpdatePosition>,
        close_position: EventHandle<ClosePosition>,
        increase_guaranteed_usd: EventHandle<IncreaseGuaranteedUsd>,
        decrease_guaranteed_usd: EventHandle<DecreaseGuaranteedUsd>,
        update_funding_rate: EventHandle<UpdateFundingRate>,
        update_pnl: EventHandle<UpdatePnl>,
    }

    ///////////////////////////////
    /// Error
    ///////////////////////////////
    const ENOT_WHITELISTED: u64 = 2;
    const EINVALID_POOL_AMOUNT: u64 = 3;
    const EADD_LIQUIDITY_FAILED: u64 = 4;
    const EMAX_LP_AMOUNT: u64 = 5;
    const EREMOVE_LIQUIDITY_FAILED: u64 = 6;
    const ESWAP_PAIR_EQUAL: u64 = 7;
    const ESTABLE: u64 = 8;
    const ENOT_STABLE: u64 = 9;
    const ENOT_SHORTABLE: u64 = 10;
    const EINVALID_POSITION_SIZE: u64 = 11;
    const EINVALID_POSITION: u64 = 12;
    const EINVALID_POSITION_FEE: u64 = 13;
    const EINVALID_AVERAGE_PRICE: u64 = 14;
    const EMAX_SHORT_EXCEEDED: u64 = 15;
    const EINVALID_POSITION_COLLATERAL: u64 = 16;
    const EINSUFFICIENT_RESERVE: u64 = 17;
    const EMAX_FEE_BASIS_POINTS: u64 = 18;
    const EFEE_RESERVE_IS_ZERO: u64 = 19;
    
    ///////////////////////////////
    /// Run when the module is published
    ///////////////////////////////
    fun init_module(sender: &signer) {
        let (resource_signer, resource_signer_cap) = account::create_resource_account(sender, b"vault");

        flp::initialize(sender, &resource_signer);
        coin::register<FLP>(&resource_signer);

        move_to(
            sender,
            VaultStore {
                signer_cap: resource_signer_cap,
                total_coin_weights: 0,
            },
        );

        move_to(
            sender,
            VaultFundStore {
                funding_interval: 8*60*60, // 8 hours
                funding_rate_factor: 1, // TODO: Check the suitable value here
                stable_funding_rate_factor: 1, // TODO: Check the suitable value here
            },
        );

        move_to(
            sender,
            VaultTradingStore {
                positions: table::new(),
                trading_fee: 10, // 0.1% (divisor = 10000)
            },
        );

        move_to(
            sender,
            VaultFeeStore {
                has_dynamic_fees: false,
                tax_basis_points: 50, // 0.5%
                stable_tax_basis_points: 20, // 0.2%
                mint_burn_fee_basis_points: 30, // 0.3%
                swap_fee_basis_points: 30, // 0.3%
                stable_swap_fee_basis_points: 4, // 0.04%
            },
        );

        move_to(
            sender,
            VaultEvents {
                add_liquidity: account::new_event_handle<AddLiquidity>(sender),
                remove_liquidity: account::new_event_handle<RemoveLiquidity>(sender),
                direct_pool_deposit: account::new_event_handle<DirectPoolDeposit>(sender),
                swap: account::new_event_handle<Swap>(sender),
                increase_pool_amount: account::new_event_handle<IncreasePoolAmount>(sender),
                increase_lp_amount: account::new_event_handle<IncreaseLpAmount>(sender),
                decrease_pool_amount: account::new_event_handle<DecreasePoolAmount>(sender),
                decrease_lp_amount: account::new_event_handle<DecreaseLpAmount>(sender),
                increase_reserved_amount: account::new_event_handle<IncreaseReservedAmount>(sender),
                decrease_reserved_amount: account::new_event_handle<DecreaseReservedAmount>(sender),
                collect_margin_fees: account::new_event_handle<CollectMarginFees>(sender),
                collect_swap_fees: account::new_event_handle<CollectSwapFees>(sender),
                increase_long_position: account::new_event_handle<IncreaseLongPosition>(sender),
                increase_short_position: account::new_event_handle<IncreaseShortPosition>(sender),
                decrease_long_position: account::new_event_handle<DecreaseLongPosition>(sender),
                decrease_short_position: account::new_event_handle<DecreaseShortPosition>(sender),
                update_position: account::new_event_handle<UpdatePosition>(sender),
                close_position: account::new_event_handle<ClosePosition>(sender),
                increase_guaranteed_usd: account::new_event_handle<IncreaseGuaranteedUsd>(sender),
                decrease_guaranteed_usd: account::new_event_handle<DecreaseGuaranteedUsd>(sender),
                update_funding_rate: account::new_event_handle<UpdateFundingRate>(sender),
                update_pnl: account::new_event_handle<UpdatePnl>(sender),
            },
        );
    }

    ///////////////////////////////
    /// WHITELIST COINS
    ///////////////////////////////
    public entry fun set_coin_config<CoinType>(
        sender: &signer,
        weight: u64,
        min_profit_bps: u128,
        max_lp_amount: u128,
        is_whitelist: bool,
        is_stable: bool,
        is_shortable: bool
    ) acquires VaultStore, VaultCoinStore {
        fewcha_access::onlyGov(sender);
        let vault_store = borrow_global_mut<VaultStore>(@module_addr);

        let new_coin_config = CoinConfig {
            weight,
            min_profit_bps,
            max_lp_amount,
            is_whitelist,
            is_stable,
            is_shortable
        };

        if (exists<VaultCoinStore<CoinType>>(@module_addr)) {
            let vault_coin_store = borrow_global_mut<VaultCoinStore<CoinType>>(@module_addr);
            vault_store.total_coin_weights = vault_store.total_coin_weights - vault_coin_store.config.weight;
            vault_coin_store.config = new_coin_config;
        } else {
            move_to(
                sender,
                VaultCoinStore<CoinType> {
                    config: new_coin_config,

                    // Pool
                    pool_amount: 0,
                    lp_amount: 0,

                    // Fund
                    cumulative_funding_rate: 0,
                    last_funding_time: 0,

                    // Trading
                    reserved_amount: 0,

                    //// Long
                    guaranteed_usd: 0,

                    //// Short
                    short_size: 0,
                    max_short_size: 0,
                    short_average_price: 0,

                    // Fee
                    fee_reserve: 0,
                },
            )
        };

        vault_store.total_coin_weights = vault_store.total_coin_weights + weight;
    }

    ///////////////////////////////
    /// LIQUIDITY PROVIDE
    ///////////////////////////////
    // Add coin CoinType and receive minted FLP in return
    public entry fun add_liquidity<CoinType>(
        sender: &signer,
        amount: u128,
    ) acquires VaultStore, VaultFundStore, VaultFeeStore, VaultCoinStore, VaultEvents {
        isWhitelisted<CoinType>();

        // Transfer In
        let vault_store = borrow_global_mut<VaultStore>(@module_addr);
        let resource_signer = account::create_signer_with_capability(&vault_store.signer_cap);
        let resource_signer_addr = signer::address_of(&resource_signer);

        if (!coin::is_account_registered<CoinType>(resource_signer_addr)){
            coin::register<CoinType>(&resource_signer);
        };

        coin::transfer<CoinType>(sender, resource_signer_addr, (amount as u64));

        // Calculate LP Amount for minting
        updateCumulativeFundingRate<CoinType>();

        let price = fewcha_vault_price_feed::getPrice<CoinType>();

        let lp_amount = amount * price / pricePrecision();
        lp_amount = adjustForDecimals<CoinType, FLP>(lp_amount);

        assert!(lp_amount > 0, error::invalid_state(EADD_LIQUIDITY_FAILED));
    
        // Calc mint fee
        let vault_fee_store = borrow_global<VaultFeeStore>(@module_addr);
        let fee_basis_points = getFeeBasisPoints<CoinType>(lp_amount, vault_fee_store.mint_burn_fee_basis_points, vault_fee_store.tax_basis_points, true);
        let token_amount_after_fees = collectSwapFees<CoinType>(amount, fee_basis_points);

        let lp_amount = token_amount_after_fees * price / pricePrecision();
        lp_amount = adjustForDecimals<CoinType, FLP>(lp_amount);

        increasePoolAmount<CoinType>(token_amount_after_fees);
        increaseLpAmount<CoinType>(lp_amount);

        // Mint FLP
        let lp_provider = signer::address_of(sender);

        if (!coin::is_account_registered<FLP>(lp_provider)){
            coin::register<FLP>(sender);
        };
        
        managed_coin::mint<FLP>(
            &resource_signer,
            lp_provider,
            (lp_amount as u64),
        );

        let coin_type = type_info::type_name<CoinType>();
        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        event::emit_event(&mut vault_events.add_liquidity, AddLiquidity {
            lp_provider,
            coin_type,
            amount,
            lp_amount,
            fee_basis_points
        });
    }

    // Burn FLP and receive coin CoinType in return
    public entry fun remove_liquidity<CoinType>(
        sender: &signer,
        lp_amount: u128,
    ) acquires VaultStore, VaultFundStore, VaultFeeStore, VaultCoinStore, VaultEvents {
        isWhitelisted<CoinType>();

        // Calculate Coin Amount for transfer out
        let price = fewcha_vault_price_feed::getPrice<CoinType>();
        
        let amount = lp_amount * pricePrecision() / price;
        amount = adjustForDecimals<FLP, CoinType>(amount);

        assert!(amount > 0, error::invalid_state(EREMOVE_LIQUIDITY_FAILED));

        updateCumulativeFundingRate<CoinType>();

        let vault_store = borrow_global_mut<VaultStore>(@module_addr);

        // Burn FLP
        let resource_signer = account::create_signer_with_capability(&vault_store.signer_cap);
        let resource_signer_addr = signer::address_of(&resource_signer);
        let lp_provider = signer::address_of(sender);
        coin::transfer<FLP>(sender, resource_signer_addr, (lp_amount as u64));
        managed_coin::burn<FLP>(
            &resource_signer,
            (lp_amount as u64),
        );

        // Calc fee
        let vault_fee_store = borrow_global<VaultFeeStore>(@module_addr);
        let fee_basis_points = getFeeBasisPoints<CoinType>(lp_amount, vault_fee_store.mint_burn_fee_basis_points, vault_fee_store.tax_basis_points, false);
        let token_amount_after_fees = collectSwapFees<CoinType>(amount, fee_basis_points);
        assert!(token_amount_after_fees > 0, error::invalid_state(EREMOVE_LIQUIDITY_FAILED));

        // Transfer out
        coin::transfer<CoinType>(&resource_signer, lp_provider, (token_amount_after_fees as u64));

        decreasePoolAmount<CoinType>(amount);
        decreaseLpAmount<CoinType>(lp_amount);

        let coin_type = type_info::type_name<CoinType>();
        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        event::emit_event(&mut vault_events.remove_liquidity, RemoveLiquidity {
            lp_provider,
            coin_type,
            amount,
            lp_amount,
            fee_basis_points
        });
    }

    // Add coin CoinType without mint FLP
    public entry fun direct_pool_deposit<CoinType>(
        sender: &signer,
        amount: u128,
    ) acquires VaultStore, VaultCoinStore, VaultEvents {
        isWhitelisted<CoinType>();
        increasePoolAmount<CoinType>(amount);

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        let coin_type = type_info::type_name<CoinType>();

        event::emit_event(&mut vault_events.direct_pool_deposit, DirectPoolDeposit {
            lp_provider: signer::address_of(sender),
            coin_type,
            amount
        });
    }

    ///////////////////////////////
    /// SWAP
    ///////////////////////////////
    public entry fun swap<CoinTypeIn, CoinTypeOut> (
        sender: &signer,
        amount_in: u128
    ) acquires VaultStore, VaultFeeStore, VaultFundStore, VaultCoinStore, VaultEvents {
        isWhitelisted<CoinTypeIn>();
        isWhitelisted<CoinTypeOut>();

        let coin_type_in = type_info::type_name<CoinTypeIn>();
        let coin_type_out = type_info::type_name<CoinTypeOut>();

        assert!(coin_type_in != coin_type_out, error::invalid_state(ESWAP_PAIR_EQUAL));

        updateCumulativeFundingRate<CoinTypeIn>();
        updateCumulativeFundingRate<CoinTypeOut>();

        // Transfer In
        let vault_store = borrow_global_mut<VaultStore>(@module_addr);
        let resource_signer = account::create_signer_with_capability(&vault_store.signer_cap);
        let resource_signer_addr = signer::address_of(&resource_signer);
        coin::transfer<CoinTypeIn>(sender, resource_signer_addr, (amount_in as u64));

        // Calculate amount out
        let price_in = fewcha_vault_price_feed::getPrice<CoinTypeIn>();
        let price_out = fewcha_vault_price_feed::getPrice<CoinTypeOut>();
        let amount_out = amount_in * price_in / price_out;
        amount_out = adjustForDecimals<CoinTypeIn, CoinTypeOut>(amount_out);

        // Calculate lpAmount - adjust lpAmount by the same lpAmount as debt is shifted between the assets
        let lp_amount = amount_in * price_in / pricePrecision();
        lp_amount = adjustForDecimals<CoinTypeIn, FLP>(lp_amount);

        let fee_basis_points = getSwapFeeBasisPoints<CoinTypeIn, CoinTypeOut>(lp_amount);
        let token_amount_out_after_fees = collectSwapFees<CoinTypeOut>(amount_out, fee_basis_points);
        
        // Trasfer out
        let sender_addr = signer::address_of(sender);
        if (!coin::is_account_registered<CoinTypeOut>(sender_addr)){
            coin::register<CoinTypeOut>(sender);
        };
        coin::transfer<CoinTypeOut>(&resource_signer, sender_addr, (token_amount_out_after_fees as u64));

        increasePoolAmount<CoinTypeIn>(amount_in);
        decreasePoolAmount<CoinTypeOut>(amount_out);

        increaseLpAmount<CoinTypeIn>(lp_amount);
        decreaseLpAmount<CoinTypeOut>(lp_amount);

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        event::emit_event(&mut vault_events.swap, Swap {
            sender_addr,
            coin_type_in, 
            coin_type_out, 
            amount_in, 
            amount_out,
            token_amount_out_after_fees,
            fee_basis_points
        });
    }

    ///////////////////////////////
    /// TRADING
    ///////////////////////////////
    // increase position
    public entry fun increase_long_position<CoinType> (
        sender: &signer,
        amount: u128,
        size_delta: u128,
    ) acquires VaultStore, VaultFundStore, VaultTradingStore, VaultCoinStore, VaultEvents {
        // TODO: leverage enable/disable

        validateLongIncrease<CoinType>();

        updateCumulativeFundingRate<CoinType>();

        let sender_addr = signer::address_of(sender);
        let position_key = getLongPositionKey<CoinType>(sender_addr);

        let price = fewcha_vault_price_feed::getPrice<CoinType>();

        let (fee_usd, collateral_delta_usd, reserve_delta) = {
            // Update position data
            let vault_trading_store = borrow_global_mut<VaultTradingStore>(@module_addr);
            if (!table::contains(&vault_trading_store.positions, position_key)) {
                table::add(&mut vault_trading_store.positions, position_key, Position {
                    size: 0,
                    collateral: 0,
                    average_price: price,
                    entry_funding_rate: 0,
                    reserve_amount: 0,
                    realised_pnl: 0,
                    last_increased_time: 0
                });
            };
            let position = table::borrow_mut(&mut vault_trading_store.positions, position_key);
            if (position.size > 0 && size_delta > 0) {
                let coin_config = isWhitelisted<CoinType>();

                position.average_price = getNextAveragePrice<CoinType>(
                    true, 
                    position.size, 
                    position.average_price, 
                    price, 
                    size_delta, 
                    position.last_increased_time,
                    coin_config.min_profit_bps
                );
            };

            // Deposit collateral
            let vault_store = borrow_global_mut<VaultStore>(@module_addr);
            let resource_signer = account::create_signer_with_capability(&vault_store.signer_cap);
            let resource_signer_addr = signer::address_of(&resource_signer);
            coin::transfer<CoinType>(sender, resource_signer_addr, (amount as u64));
            
            let collateral_delta_usd = coinToUsd<CoinType>(amount, price);
            position.collateral = position.collateral + collateral_delta_usd;
            position.size = position.size + size_delta;

            // Calc position fee
            let fee_usd = collectMarginFees<CoinType>(size_delta, position.size, position.entry_funding_rate, price, vault_trading_store.trading_fee);

            // Charge fee directly from collateral
            assert!(position.collateral >= fee_usd, error::invalid_state(EINVALID_POSITION_FEE));
            position.collateral = position.collateral - fee_usd;

            // TODO: Update entry funding rate
            // position.entry_funding_rate = getEntryFundingRate(_collateralToken, _indexToken, _isLong);
            position.last_increased_time = timestamp::now_seconds();

            // Validate
            std::debug::print(position);
            assert!(position.size >= position.collateral, error::invalid_state(EINVALID_POSITION_SIZE));
            // TODO: validateLiquidation();

            let reserve_delta = usdToCoin<CoinType>(size_delta, price);
            position.reserve_amount = position.reserve_amount + reserve_delta;

            (fee_usd, collateral_delta_usd, reserve_delta)
        };

        increaseReservedAmount<CoinType>(reserve_delta);

        // guaranteedUsd stores the sum of (position.size - position.collateral) for all positions
        // if a fee is charged on the collateral then guaranteedUsd should be increased by that fee amount
        // since (position.size - position.collateral) would have increased by `fee`
        increaseGuaranteedUsd<CoinType>(size_delta + fee_usd);
        decreaseGuaranteedUsd<CoinType>(collateral_delta_usd);
        // treat the deposited collateral as part of the pool
        increasePoolAmount<CoinType>(reserve_delta);
        // fees need to be deducted from the pool since fees are deducted from position.collateral
        // and collateral is treated as part of the pool
        let fee_coin_amount = usdToCoin<CoinType>(fee_usd, price);
        decreasePoolAmount<CoinType>(fee_coin_amount);

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        let coin_type = type_info::type_name<CoinType>();
        event::emit_event(&mut vault_events.increase_long_position, IncreaseLongPosition {
            position_key,
            sender_addr,
            coin_type,
            collateral_delta_usd,
            size_delta,
            price,
            fee_usd
        });

        let vault_trading_store = borrow_global<VaultTradingStore>(@module_addr);
        let position = table::borrow(&vault_trading_store.positions, position_key);
        event::emit_event(&mut vault_events.update_position, UpdatePosition {
            position_key,
            size: position.size,
            collateral: position.collateral, 
            average_price: position.average_price, 
            entry_funding_rate: position.entry_funding_rate, 
            reserve_amount: position.reserve_amount, 
            realised_pnl: position.realised_pnl, 
            price
        });
    }

    public entry fun increase_short_position<CoinTypeCollateral, CoinTypeIndex> (
        sender: &signer,
        amount: u128,
        size_delta: u128,
    ) acquires VaultStore, VaultFundStore, VaultTradingStore, VaultCoinStore, VaultEvents {
        // TODO: leverage enable/disable

        validateShortIncrease<CoinTypeCollateral, CoinTypeIndex>();

        updateCumulativeFundingRate<CoinTypeCollateral>();

        let sender_addr = signer::address_of(sender);
        let position_key = getShortPositionKey<CoinTypeCollateral, CoinTypeIndex>(sender_addr);

        let price = fewcha_vault_price_feed::getPrice<CoinTypeIndex>();

        let (fee_usd, collateral_delta_usd, reserve_delta) = {
            // Update position data
            let vault_trading_store = borrow_global_mut<VaultTradingStore>(@module_addr);
            if (!table::contains(&vault_trading_store.positions, position_key)) {
                table::add(&mut vault_trading_store.positions, position_key, Position {
                    size: 0,
                    collateral: 0,
                    average_price: price,
                    entry_funding_rate: 0,
                    reserve_amount: 0,
                    realised_pnl: 0,
                    last_increased_time: 0
                });
            };
            let position = table::borrow_mut(&mut vault_trading_store.positions, position_key);
            if (position.size > 0 && size_delta > 0) {
                let coin_config = isWhitelisted<CoinTypeIndex>();

                position.average_price = getNextAveragePrice<CoinTypeIndex>(
                    false, 
                    position.size, 
                    position.average_price, 
                    price, 
                    size_delta, 
                    position.last_increased_time,
                    coin_config.min_profit_bps
                );
            };

            // Deposit collateral
            let vault_store = borrow_global_mut<VaultStore>(@module_addr);
            let resource_signer = account::create_signer_with_capability(&vault_store.signer_cap);
            let resource_signer_addr = signer::address_of(&resource_signer);
            coin::transfer<CoinTypeCollateral>(sender, resource_signer_addr, (amount as u64));
            
            let collateral_delta_usd = coinToUsd<CoinTypeCollateral>(amount, price); // Actual this is already stable ~ 1:1
            position.collateral = position.collateral + collateral_delta_usd;
            position.size = position.size + size_delta;

            // Calc position fee
            let fee_usd = collectMarginFees<CoinTypeCollateral>(size_delta, position.size, position.entry_funding_rate, price, vault_trading_store.trading_fee);

            // Charge fee directly from collateral
            assert!(position.collateral >= fee_usd, error::invalid_state(EINVALID_POSITION_FEE));
            position.collateral = position.collateral - fee_usd;

            // TODO: Update entry funding rate
            // position.entry_funding_rate = getEntryFundingRate(_collateralToken, _indexToken, _isLong);
            position.last_increased_time = timestamp::now_seconds();

            // Validate
            assert!(position.size >= position.collateral, error::invalid_state(EINVALID_POSITION_SIZE));
            // TODO: validateLiquidation();

            let reserve_delta = usdToCoin<CoinTypeCollateral>(size_delta, price);
            position.reserve_amount = position.reserve_amount + reserve_delta;

            (fee_usd, collateral_delta_usd, reserve_delta)
        };

        increaseReservedAmount<CoinTypeCollateral>(reserve_delta);

        {
            let vault_coin_store = borrow_global_mut<VaultCoinStore<CoinTypeIndex>>(@module_addr);

            if (vault_coin_store.short_size == 0) {
                vault_coin_store.short_average_price = getNextShortAveragePrice(vault_coin_store.short_average_price, price, vault_coin_store.short_size, size_delta);
            } else {
                vault_coin_store.short_average_price = price;
            };
        };

        increaseShortSize<CoinTypeIndex>(size_delta);

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        let coin_type_collateral = type_info::type_name<CoinTypeCollateral>();
        let coin_type_index = type_info::type_name<CoinTypeIndex>();
        event::emit_event(&mut vault_events.increase_short_position, IncreaseShortPosition {
            position_key,
            sender_addr,
            coin_type_collateral,
            coin_type_index,
            collateral_delta_usd,
            size_delta,
            price,
            fee_usd
        });

        let vault_trading_store = borrow_global<VaultTradingStore>(@module_addr);
        let position = table::borrow(&vault_trading_store.positions, position_key);
        event::emit_event(&mut vault_events.update_position, UpdatePosition {
            position_key,
            size: position.size,
            collateral: position.collateral, 
            average_price: position.average_price, 
            entry_funding_rate: position.entry_funding_rate, 
            reserve_amount: position.reserve_amount, 
            realised_pnl: position.realised_pnl, 
            price
        });
    }

    // Decrease position
    public entry fun decrease_long_position<CoinType> (
        sender: &signer,
        collateral_delta: u128, 
        size_delta: u128,
    ) acquires VaultFundStore, VaultTradingStore, VaultStore, VaultCoinStore, VaultEvents {
        updateCumulativeFundingRate<CoinType>();

        let sender_addr = signer::address_of(sender);
        let position_key = getLongPositionKey<CoinType>(sender_addr);

        let (collateral, reserve_delta, close_all) = {
            let vault_trading_store = borrow_global_mut<VaultTradingStore>(@module_addr);
            let position = table::borrow_mut(&mut vault_trading_store.positions, position_key);

            assert!(position.size > size_delta && size_delta > 0, error::invalid_state(EINVALID_POSITION_SIZE));
            assert!(position.collateral >= collateral_delta, error::invalid_state(EINVALID_POSITION_COLLATERAL));

            let reserve_delta = position.reserve_amount * size_delta / position.size;
            position.reserve_amount = position.reserve_amount - reserve_delta;

            let close_all = position.size == size_delta;

            (position.collateral, reserve_delta, close_all)
        };
        decreaseReservedAmount<CoinType>(reserve_delta);

        let (usd_out, usd_out_after_fee) = reduceCollateral<CoinType>(position_key, collateral_delta, size_delta, true);
        if (!close_all) {
            let vault_trading_store = borrow_global_mut<VaultTradingStore>(@module_addr);
            let position = table::borrow_mut(&mut vault_trading_store.positions, position_key);

            // TODO: position.entryFundingRate = getEntryFundingRate(_collateralToken, _indexToken, _isLong);
            position.size = position.size - size_delta;

            assert!(
                (position.size == 0 && position.collateral == 0)
                || (position.size >= position.collateral), error::invalid_state(EINVALID_POSITION)
            );
            // TODO: validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);

            increaseGuaranteedUsd<CoinType>(collateral - position.collateral);
        } else {
            increaseGuaranteedUsd<CoinType>(collateral);
        };

        decreaseGuaranteedUsd<CoinType>(size_delta);

        let price = fewcha_vault_price_feed::getPrice<CoinType>();

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        let coin_type = type_info::type_name<CoinType>();

        let fee_usd = usd_out - usd_out_after_fee;
        event::emit_event(&mut vault_events.decrease_long_position, DecreaseLongPosition {
            position_key,
            sender_addr,
            coin_type,
            collateral_delta_usd: collateral_delta,
            size_delta,
            price,
            fee_usd
        });

        if (close_all) {
            let vault_trading_store = borrow_global_mut<VaultTradingStore>(@module_addr);
            let position = table::borrow(&vault_trading_store.positions, position_key);
            event::emit_event(&mut vault_events.close_position, ClosePosition {
                position_key,
                size: position.size,
                collateral: position.collateral, 
                average_price: position.average_price, 
                entry_funding_rate: position.entry_funding_rate, 
                reserve_amount: position.reserve_amount, 
                realised_pnl: position.realised_pnl, 
            });

            table::remove(&mut vault_trading_store.positions, position_key);
        } else {
            let vault_trading_store = borrow_global<VaultTradingStore>(@module_addr);
            let position = table::borrow(&vault_trading_store.positions, position_key);

            event::emit_event(&mut vault_events.update_position, UpdatePosition {
                position_key,
                size: position.size,
                collateral: position.collateral, 
                average_price: position.average_price, 
                entry_funding_rate: position.entry_funding_rate, 
                reserve_amount: position.reserve_amount, 
                realised_pnl: position.realised_pnl, 
                price
            });
        };

        if (usd_out > 0) {
            decreasePoolAmount<CoinType>(usdToCoin<CoinType>(usd_out, price));
            let amount_out_after_fee = usdToCoin<CoinType>(usd_out_after_fee, price);

            // Transfer out
            let vault_store = borrow_global_mut<VaultStore>(@module_addr);
            let resource_signer = account::create_signer_with_capability(&vault_store.signer_cap);
            coin::transfer<CoinType>(&resource_signer, sender_addr, (amount_out_after_fee as u64));
        };
    }

    // // decrease position
    public entry fun decrease_short_position<CoinTypeCollateral, CoinTypeIndex> (
        sender: &signer,
        collateral_delta: u128, 
        size_delta: u128,
    ) acquires VaultStore, VaultTradingStore, VaultFundStore, VaultCoinStore, VaultEvents {
        updateCumulativeFundingRate<CoinTypeCollateral>();

        let sender_addr = signer::address_of(sender);
        let position_key = getShortPositionKey<CoinTypeCollateral, CoinTypeIndex>(sender_addr);

        let (reserve_delta, close_all) = {
            let vault_trading_store = borrow_global_mut<VaultTradingStore>(@module_addr);
            let position = table::borrow_mut(&mut vault_trading_store.positions, position_key);

            assert!(position.size > size_delta && size_delta > 0, error::invalid_state(EINVALID_POSITION_SIZE));
            assert!(position.collateral >= collateral_delta, error::invalid_state(EINVALID_POSITION_COLLATERAL));

            let reserve_delta = position.reserve_amount * size_delta / position.size;
            position.reserve_amount = position.reserve_amount - reserve_delta;

            let close_all = position.size == size_delta;

            (reserve_delta, close_all)
        };
        decreaseReservedAmount<CoinTypeCollateral>(reserve_delta);

        let (usd_out, usd_out_after_fee) = reduceCollateral<CoinTypeCollateral>(position_key, collateral_delta, size_delta, false);
        if (!close_all) {
            let vault_trading_store = borrow_global_mut<VaultTradingStore>(@module_addr);
            let position = table::borrow_mut(&mut vault_trading_store.positions, position_key);

            // TODO: position.entryFundingRate = getEntryFundingRate(_collateralToken, _indexToken, _isLong);
            position.size = position.size - size_delta;

            assert!(
                (position.size == 0 && position.collateral == 0)
                || (position.size >= position.collateral), error::invalid_state(EINVALID_POSITION)
            );
            // TODO: validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true);
        };

        let price = fewcha_vault_price_feed::getPrice<CoinTypeCollateral>();

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        let coin_type_collateral = type_info::type_name<CoinTypeCollateral>();
        let coin_type_index = type_info::type_name<CoinTypeIndex>();

        let fee_usd = usd_out - usd_out_after_fee;
        event::emit_event(&mut vault_events.decrease_short_position, DecreaseShortPosition {
            position_key,
            sender_addr,
            coin_type_collateral,
            coin_type_index,
            collateral_delta_usd: collateral_delta,
            size_delta,
            price,
            fee_usd
        });

        if (close_all) {
            let vault_trading_store = borrow_global_mut<VaultTradingStore>(@module_addr);
            let position = table::borrow(&vault_trading_store.positions, position_key);
            event::emit_event(&mut vault_events.close_position, ClosePosition {
                position_key,
                size: position.size,
                collateral: position.collateral, 
                average_price: position.average_price, 
                entry_funding_rate: position.entry_funding_rate, 
                reserve_amount: position.reserve_amount, 
                realised_pnl: position.realised_pnl, 
            });

            table::remove(&mut vault_trading_store.positions, position_key);
        } else {
            let vault_trading_store = borrow_global<VaultTradingStore>(@module_addr);
            let position = table::borrow(&vault_trading_store.positions, position_key);

            event::emit_event(&mut vault_events.update_position, UpdatePosition {
                position_key,
                size: position.size,
                collateral: position.collateral, 
                average_price: position.average_price, 
                entry_funding_rate: position.entry_funding_rate, 
                reserve_amount: position.reserve_amount, 
                realised_pnl: position.realised_pnl, 
                price
            });
        };

        decreaseShortSize<CoinTypeIndex>(size_delta);

        if (usd_out > 0) {
            let amount_out_after_fee = usdToCoin<CoinTypeCollateral>(usd_out_after_fee, price);

            // Transfer out
            let vault_store = borrow_global_mut<VaultStore>(@module_addr);
            let resource_signer = account::create_signer_with_capability(&vault_store.signer_cap);
            coin::transfer<CoinTypeCollateral>(&resource_signer, sender_addr, (amount_out_after_fee as u64));
        };
    }

    // // liquidate position
    // public entry fun liquidate_position<> (
    // ) {
    // }

    #[view]
    public fun getBalance<CoinType>(): u128 acquires VaultStore {
        let vault_store = borrow_global<VaultStore>(@module_addr);
        let resource_signer_addr = account::get_signer_capability_address(&vault_store.signer_cap);
        let coin_balance = coin::balance<CoinType>(resource_signer_addr);
        (coin_balance as u128)
    }

    public entry fun withdraw_fees<CoinType>(
        sender: &signer, 
        receiver: address
    ) acquires VaultStore, VaultCoinStore {
        fewcha_access::onlyGov(sender);
        let vault_coin_store = borrow_global_mut<VaultCoinStore<CoinType>>(@module_addr);
        let amount = vault_coin_store.fee_reserve;
        assert!(amount > 0, error::invalid_state(EFEE_RESERVE_IS_ZERO));
        vault_coin_store.fee_reserve = 0;

        // Transfer out
        let vault_store = borrow_global<VaultStore>(@module_addr);
        let resource_signer = account::create_signer_with_capability(&vault_store.signer_cap);
        coin::transfer<CoinType>(&resource_signer, receiver, (amount as u64));
    }

    public entry fun set_fees(
        sender: &signer,
        tax_basis_points: u128,
        stable_tax_basis_points: u128,
        mint_burn_fee_basis_points: u128,
        swap_fee_basis_points: u128,
        stable_swap_fee_basis_points: u128,
        has_dynamic_fees: bool
    ) acquires VaultFeeStore {
        fewcha_access::onlyGov(sender);
        assert!(tax_basis_points <= MAX_FEE_BASIS_POINTS, error::out_of_range(EMAX_FEE_BASIS_POINTS));
        assert!(stable_tax_basis_points <= MAX_FEE_BASIS_POINTS, error::out_of_range(EMAX_FEE_BASIS_POINTS));
        assert!(mint_burn_fee_basis_points <= MAX_FEE_BASIS_POINTS, error::out_of_range(EMAX_FEE_BASIS_POINTS));
        assert!(swap_fee_basis_points <= MAX_FEE_BASIS_POINTS, error::out_of_range(EMAX_FEE_BASIS_POINTS));
        assert!(stable_swap_fee_basis_points <= MAX_FEE_BASIS_POINTS, error::out_of_range(EMAX_FEE_BASIS_POINTS));

        let vault_fee_store = borrow_global_mut<VaultFeeStore>(@module_addr);
        vault_fee_store.tax_basis_points = tax_basis_points;
        vault_fee_store.stable_tax_basis_points = stable_tax_basis_points;
        vault_fee_store.mint_burn_fee_basis_points = mint_burn_fee_basis_points;
        vault_fee_store.swap_fee_basis_points = swap_fee_basis_points;
        vault_fee_store.stable_swap_fee_basis_points = stable_swap_fee_basis_points;
        vault_fee_store.has_dynamic_fees = has_dynamic_fees;
    }

    ///////////////////////////////
    /// PRIVATE FUNCTION
    ///////////////////////////////

    fun increasePoolAmount<CoinType>(amount: u128) acquires VaultStore, VaultCoinStore, VaultEvents {
        let vault_coin_store = borrow_global_mut<VaultCoinStore<CoinType>>(@module_addr);
        vault_coin_store.pool_amount = vault_coin_store.pool_amount + amount;

        let coin_balance = getBalance<CoinType>();
        assert!(coin_balance >= vault_coin_store.pool_amount, error::invalid_state(EINVALID_POOL_AMOUNT));

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        let coin_type = type_info::type_name<CoinType>();
        event::emit_event(&mut vault_events.increase_pool_amount, IncreasePoolAmount {
            coin_type,
            amount
        });
    }

    fun increaseLpAmount<CoinType>(amount: u128) acquires VaultCoinStore, VaultEvents {
        let vault_coin_store = borrow_global_mut<VaultCoinStore<CoinType>>(@module_addr);
        vault_coin_store.lp_amount = vault_coin_store.lp_amount + amount;

        if (vault_coin_store.config.max_lp_amount > 0) {
            assert!(vault_coin_store.lp_amount <= vault_coin_store.config.max_lp_amount, error::invalid_state(EMAX_LP_AMOUNT));
        };

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        let coin_type =  type_info::type_name<CoinType>();
        event::emit_event(&mut vault_events.increase_lp_amount, IncreaseLpAmount {
            coin_type,
            amount
        });
    }

    fun decreasePoolAmount<CoinType>(amount: u128) acquires VaultStore, VaultCoinStore, VaultEvents {
        let vault_coin_store = borrow_global_mut<VaultCoinStore<CoinType>>(@module_addr);
        vault_coin_store.pool_amount = vault_coin_store.pool_amount - amount;

        let coin_balance = getBalance<CoinType>();
        assert!(coin_balance >= vault_coin_store.pool_amount 
            && vault_coin_store.pool_amount >= vault_coin_store.reserved_amount, error::invalid_state(EINVALID_POOL_AMOUNT));

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        let coin_type =  type_info::type_name<CoinType>();
        event::emit_event(&mut vault_events.decrease_pool_amount, DecreasePoolAmount {
            coin_type,
            amount
        });
    }

    fun decreaseLpAmount<CoinType>(amount: u128) acquires VaultCoinStore, VaultEvents {
        let vault_coin_store = borrow_global_mut<VaultCoinStore<CoinType>>(@module_addr);

        // since FLP can be minted using multiple assets
        // it is possible for the FLP debt for a single asset to be less than zero
        // the FLP debt is capped to zero for this case
        vault_coin_store.lp_amount = if (vault_coin_store.lp_amount < amount) {
            0
        } else {
            vault_coin_store.lp_amount - amount
        };

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        let coin_type = type_info::type_name<CoinType>();
        event::emit_event(&mut vault_events.decrease_lp_amount, DecreaseLpAmount {
            coin_type,
            amount
        });
    }

    fun increaseGuaranteedUsd<CoinType>(
        usd_amount: u128
    ) acquires VaultCoinStore, VaultEvents {
        let vault_coin_store = borrow_global_mut<VaultCoinStore<CoinType>>(@module_addr);
        vault_coin_store.guaranteed_usd = vault_coin_store.guaranteed_usd + usd_amount;

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        let coin_type = type_info::type_name<CoinType>();
        event::emit_event(&mut vault_events.increase_guaranteed_usd, IncreaseGuaranteedUsd {
            coin_type,
            usd_amount
        });
    }

    fun decreaseGuaranteedUsd<CoinType>(
        usd_amount: u128
    ) acquires VaultCoinStore, VaultEvents  {
        let vault_coin_store = borrow_global_mut<VaultCoinStore<CoinType>>(@module_addr);
        vault_coin_store.guaranteed_usd = vault_coin_store.guaranteed_usd - usd_amount;

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        let coin_type = type_info::type_name<CoinType>();
        event::emit_event(&mut vault_events.decrease_guaranteed_usd, DecreaseGuaranteedUsd {
            coin_type,
            usd_amount
        });
    }

    fun increaseReservedAmount<CoinType>(amount: u128) acquires VaultCoinStore, VaultEvents  {
        let vault_coin_store = borrow_global_mut<VaultCoinStore<CoinType>>(@module_addr);
        vault_coin_store.reserved_amount = vault_coin_store.reserved_amount + amount;

        assert!(vault_coin_store.reserved_amount <= vault_coin_store.pool_amount, error::invalid_state(EINVALID_POOL_AMOUNT));

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        let coin_type = type_info::type_name<CoinType>();
        event::emit_event(&mut vault_events.increase_reserved_amount, IncreaseReservedAmount {
            coin_type,
            amount
        });
    }

    fun decreaseReservedAmount<CoinType>(amount: u128) acquires VaultCoinStore, VaultEvents  {
        let vault_coin_store = borrow_global_mut<VaultCoinStore<CoinType>>(@module_addr);

        assert!(vault_coin_store.reserved_amount >= amount, error::resource_exhausted(EINSUFFICIENT_RESERVE));
        vault_coin_store.reserved_amount = vault_coin_store.reserved_amount - amount;

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        let coin_type = type_info::type_name<CoinType>();
        event::emit_event(&mut vault_events.decrease_reserved_amount, DecreaseReservedAmount {
            coin_type,
            amount
        });
    }

    fun increaseShortSize<CoinTypeIndex>(
        size_delta: u128
    ) acquires VaultCoinStore {
        let vault_coin_store = borrow_global_mut<VaultCoinStore<CoinTypeIndex>>(@module_addr);
        vault_coin_store.short_size = vault_coin_store.short_size + size_delta;
        assert!(vault_coin_store.max_short_size == 0 || vault_coin_store.short_size <= vault_coin_store.max_short_size, error::out_of_range(EMAX_SHORT_EXCEEDED));
    }

    fun decreaseShortSize<CoinTypeIndex>(
        amount: u128
    ) acquires VaultCoinStore {
        let vault_coin_store = borrow_global_mut<VaultCoinStore<CoinTypeIndex>>(@module_addr);
        vault_coin_store.short_size = vault_coin_store.short_size - amount;
    }

    fun pricePrecision(): u128 {
        math128::pow(10, 9) // Switchboard return price in usd with decimals as 9
    }

    fun adjustForDecimals<CoinTypeDiv, CoinTypeMul>(_amount: u128) : u128 {
        let decimals_div = coin::decimals<CoinTypeDiv>();
        let decimals_mul = coin::decimals<CoinTypeMul>();
        _amount * math128::pow(10, (decimals_mul as u128)) / math128::pow(10, (decimals_div as u128))
    }

    fun getLongPositionKey<CoinType>(sender_addr: address): vector<u8> {
        let addr = bcs::to_bytes(&sender_addr);
        let coin_type = type_info::type_name<CoinType>();
        let coin_type = bcs::to_bytes(&coin_type);
        vector::append(&mut addr, coin_type);
        let hash_v = hash::sha3_256(addr);
        hash_v
    }

    fun getShortPositionKey<CoinTypeCollateral, CoinTypeIndex>(sender_addr: address): vector<u8> {
        let addr = bcs::to_bytes(&sender_addr);
        let coin_type_collateral = type_info::type_name<CoinTypeCollateral>();
        let coin_type_collateral = bcs::to_bytes(&coin_type_collateral);
        let coin_type_index = type_info::type_name<CoinTypeIndex>();
        let coin_type_index = bcs::to_bytes(&coin_type_index);

        vector::append(&mut addr, coin_type_collateral);
        vector::append(&mut addr, coin_type_index);
        let hash_v = hash::sha3_256(addr);
        hash_v
    }

    fun coinToUsd<CoinType>(coin_amount: u128, price: u128): u128 {
        let decimals = coin::decimals<CoinType>();
        let usd_amount = coin_amount * price / math128::pow(10, (decimals as u128));
        usd_amount
    }

    fun usdToCoin<CoinType>(usd_amount: u128, price: u128): u128 {
        let decimals = coin::decimals<CoinType>();
        let coin_amount = usd_amount * math128::pow(10, (decimals as u128)) / price;
        coin_amount
    }

    fun collectMarginFees<CoinTypeCollateral>(
        size_delta: u128, 
        size: u128,
        entry_funding_rate: u64,
        price: u128,
        trading_fee: u128,
    ) : u128 acquires VaultCoinStore, VaultEvents {
        let fee_usd = getTradingFee(size_delta, trading_fee);
        let funding_fee = getFundingFee<CoinTypeCollateral>(size, entry_funding_rate);
        fee_usd = fee_usd + funding_fee;

        let fee_coin_amount = usdToCoin<CoinTypeCollateral>(fee_usd, price);

        increaseFeeReverse<CoinTypeCollateral>(fee_coin_amount);

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        let coin_type = type_info::type_name<CoinTypeCollateral>();
        event::emit_event(&mut vault_events.collect_margin_fees, CollectMarginFees {
            coin_type,
            fee_usd,
            fee_coin_amount
        });

        fee_usd
    }

    fun getTradingFee(
        size_delta: u128, 
        trading_fee: u128,
    ) : u128 {
        if (size_delta == 0) { 
            0
        } else {
            let after_fee_usd = size_delta * (BASIS_POINTS_DIVISOR - trading_fee) / BASIS_POINTS_DIVISOR;
            size_delta - after_fee_usd
        }
    }

    fun getFundingFee<CoinTypeCollateral>(
        size: u128, 
        entry_funding_rate: u64,
    ) : u128 acquires VaultCoinStore {
        if (size == 0) { 
            0
        } else {
            let vault_coin_store = borrow_global<VaultCoinStore<CoinTypeCollateral>>(@module_addr);
            let funding_rate = vault_coin_store.cumulative_funding_rate - (entry_funding_rate as u128);
            if (funding_rate == 0) {
                0
            } else {
                size * funding_rate / FUNDING_RATE_PRECISION
            }
        }
    }

    fun increaseFeeReverse<CoinType>(
        amount: u128
    ) acquires VaultCoinStore {
        let vault_coin_store = borrow_global_mut<VaultCoinStore<CoinType>>(@module_addr);
        vault_coin_store.fee_reserve = vault_coin_store.fee_reserve + amount;
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    fun getNextAveragePrice<CoinType>(
        is_long: bool,
        size: u128,
        average_price: u128,
        next_price: u128,
        size_delta: u128,
        last_increased_time: u64,
        min_profit_bps: u128
    ): u128 {
        let (has_profit, delta) = getDelta<CoinType>(size, average_price, is_long, last_increased_time, min_profit_bps);
        let next_size = size + size_delta;
        let divisor = if (is_long) {
            if (has_profit) {
                next_size + delta
            } else {
                next_size - delta
            }
        } else {
            if (has_profit) {
                next_size - delta
            } else {
                next_size + delta
            }
        };
        next_price * next_size / divisor
    }

    fun getDelta<CoinType>(
        size: u128, 
        average_price: u128, 
        is_long: bool, 
        last_increased_time: u64,
        min_profit_bps: u128
    ) : (bool, u128) {
        assert!(average_price > 0, error::invalid_state(EINVALID_AVERAGE_PRICE));
        let price = fewcha_vault_price_feed::getPrice<CoinType>();

        let price_delta = if (average_price > price) {
            average_price - price
        } else {
            price - average_price
        };
        let delta = size * price_delta / average_price;

        let has_profit = if (is_long) {
            price > average_price
        } else {
            average_price > price
        };

        // if the minProfitTime has passed then there will be no min profit threshold
        // the min profit threshold helps to prevent front-running issues
        let min_bps = if (timestamp::now_seconds() > last_increased_time + MIN_PROFIT_TIME) {
            0
        } else {
            min_profit_bps
        };
        if (has_profit && delta * BASIS_POINTS_DIVISOR <= size * min_bps) {
            delta = 0;
        };

        (has_profit, delta)
    }

    fun getNextShortAveragePrice(
        short_average_price: u128,
        price: u128,
        short_size: u128,
        size_delta: u128,
    ) : u128 {
        let price_delta = if (short_average_price > price) {
            short_average_price - price
        } else {
            price - short_average_price
        };
        let delta = short_size * price_delta / short_average_price;
        let has_profit = short_average_price > price;

        let next_size = short_size + size_delta;
        let divisor = if (has_profit) {
            next_size - delta
        } else {
            next_size + delta
        };

        price * next_size / divisor
    }

    fun reduceCollateral<CoinType>(
        position_key: vector<u8>,
        collateral_delta: u128,
        size_delta: u128,
        is_long: bool
    ) : (u128, u128) acquires VaultStore, VaultTradingStore, VaultCoinStore, VaultEvents {
        let vault_trading_store = borrow_global_mut<VaultTradingStore>(@module_addr);
        let position = table::borrow_mut(&mut vault_trading_store.positions, position_key);

        // Calc position fee
        let price = fewcha_vault_price_feed::getPrice<CoinType>();
        let fee_usd = collectMarginFees<CoinType>(size_delta, position.size, position.entry_funding_rate, price, vault_trading_store.trading_fee);

        let coin_config = isWhitelisted<CoinType>();
        let (has_profit, delta) = getDelta<CoinType>(position.size, position.average_price, is_long, position.last_increased_time, coin_config.min_profit_bps);
        let adjusted_delta = size_delta * delta / position.size;

        let usd_out = 0;
        // transfer profits out
        if (has_profit && adjusted_delta > 0) {
            usd_out = adjusted_delta;
            position.realised_pnl = position.realised_pnl + adjusted_delta;

            // pay out realised profits from the pool amount for short positions
            if (!is_long) {
                let token_amount = usdToCoin<CoinType>(adjusted_delta, price);
                decreasePoolAmount<CoinType>(token_amount);
            }
        };

        if (!has_profit && adjusted_delta > 0) {
            position.collateral = position.collateral - adjusted_delta;
            position.realised_pnl = position.realised_pnl - adjusted_delta;

            // transfer realised losses to the pool for short positions
            // realised losses for long positions are not transferred here as
            // _increasePoolAmount was already called in increasePosition for longs
            if (!is_long) {
                let token_amount = usdToCoin<CoinType>(adjusted_delta, price);
                increasePoolAmount<CoinType>(token_amount);
            }
        };

        // reduce the position's collateral by collateral_delta
        // transfer collateral_delta out
        if (collateral_delta > 0) {
            usd_out = usd_out + collateral_delta;
            position.collateral = position.collateral - collateral_delta;
        };

        // if the position will be closed, then transfer the remaining collateral out
        if (position.size == size_delta) {
            usd_out = usd_out + position.collateral;
            position.collateral = 0;
        };

        // if the usdOut is more than the fee then deduct the fee from the usdOut directly
        // else deduct the fee from the position's collateral
        let usd_out_after_fee = usd_out;
        if (usd_out > fee_usd) {
            usd_out_after_fee = usd_out - fee_usd;
        } else {
            position.collateral = position.collateral - fee_usd;
            if (is_long) {
                let fee_coin = usdToCoin<CoinType>(fee_usd, price);
                decreasePoolAmount<CoinType>(fee_coin);
            }
        };

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        event::emit_event(&mut vault_events.update_pnl, UpdatePnl {
            position_key,
            has_profit,
            adjusted_delta
        });

        (usd_out, usd_out_after_fee)
    }

    fun updateCumulativeFundingRate<CoinType>() acquires VaultFundStore, VaultCoinStore, VaultEvents {
        let now = timestamp::now_seconds();
        let coin_config = isWhitelisted<CoinType>();

        let vault_coin_store = borrow_global_mut<VaultCoinStore<CoinType>>(@module_addr);
        let vault_fund_store = borrow_global<VaultFundStore>(@module_addr);

        // Make timestamp divable by interval
        let now_interval_divable = now / vault_fund_store.funding_interval * vault_fund_store.funding_interval;

        if (vault_coin_store.last_funding_time == 0) {
            vault_coin_store.last_funding_time = now_interval_divable;
        } else {
            if (vault_coin_store.last_funding_time + vault_fund_store.funding_interval < now) {

                let funding_rate = {
                    let intervals = (now_interval_divable - vault_coin_store.last_funding_time) / vault_fund_store.funding_interval;

                    if (vault_coin_store.pool_amount > 0) {

                        let funding_rate_factor = if (coin_config.is_stable) {
                            vault_fund_store.stable_funding_rate_factor
                        } else {
                            vault_fund_store.funding_rate_factor
                        };
                        
                        (funding_rate_factor as u128) * vault_coin_store.reserved_amount * (intervals as u128) / (vault_coin_store.pool_amount)
                    } else {
                        0
                    }
                };

                vault_coin_store.cumulative_funding_rate = vault_coin_store.cumulative_funding_rate + funding_rate;
                vault_coin_store.last_funding_time = now_interval_divable;

                let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
                let coin_type = type_info::type_name<CoinType>();
                event::emit_event(&mut vault_events.update_funding_rate, UpdateFundingRate {
                    coin_type,
                    cumulative_funding_rate: vault_coin_store.cumulative_funding_rate
                });
            }
        };
    }

    fun collectSwapFees<CoinType>(amount: u128, fee_basis_points: u128) : u128 acquires VaultCoinStore, VaultEvents {
        let after_fee_amount = amount * (BASIS_POINTS_DIVISOR - fee_basis_points) / BASIS_POINTS_DIVISOR;
        let fee_amount = amount - after_fee_amount;

        increaseFeeReverse<CoinType>(fee_amount);

        let vault_events = borrow_global_mut<VaultEvents>(@module_addr);
        let coin_type = type_info::type_name<CoinType>();
        let price = fewcha_vault_price_feed::getPrice<CoinType>();
        let fee_usd = coinToUsd<CoinType>(fee_amount, price);
        event::emit_event(&mut vault_events.collect_swap_fees, CollectSwapFees {
            coin_type,
            fee_usd,
            fee_coin_amount: fee_amount
        });

        after_fee_amount
    }

    fun getSwapFeeBasisPoints<CoinTypeIn, CoinTypeOut>(lp_amount: u128): u128 acquires VaultStore, VaultFeeStore, VaultCoinStore {
        let coin_in_config = isWhitelisted<CoinTypeIn>();
        let coin_out_config = isWhitelisted<CoinTypeOut>();
        let is_stable_swap = coin_in_config.is_stable && coin_out_config.is_stable;

        let vault_fee_store = borrow_global<VaultFeeStore>(@module_addr);

        let base_bps = if (is_stable_swap) {
            vault_fee_store.stable_swap_fee_basis_points
        } else {
            vault_fee_store.swap_fee_basis_points
        };

        let tax_bps = if (is_stable_swap) {
            vault_fee_store.stable_tax_basis_points
        } else {
            vault_fee_store.tax_basis_points
        };

        let fee_basis_points_in = getFeeBasisPoints<CoinTypeIn>(lp_amount, base_bps, tax_bps, true);
        let fee_basis_points_out = getFeeBasisPoints<CoinTypeOut>(lp_amount, base_bps, tax_bps, false);

        // use the higher of the two fee basis points
        if (fee_basis_points_in > fee_basis_points_out) {
            fee_basis_points_in
        } else {
            fee_basis_points_out
        }
    }

    // cases to consider
    // 1. initialAmount is far from targetAmount, action increases balance slightly => high rebate
    // 2. initialAmount is far from targetAmount, action increases balance largely => high rebate
    // 3. initialAmount is close to targetAmount, action increases balance slightly => low rebate
    // 4. initialAmount is far from targetAmount, action reduces balance slightly => high tax
    // 5. initialAmount is far from targetAmount, action reduces balance largely => high tax
    // 6. initialAmount is close to targetAmount, action reduces balance largely => low tax
    // 7. initialAmount is above targetAmount, nextAmount is below targetAmount and vice versa
    // 8. a large swap should have similar fees as the same trade split into multiple smaller swaps
    fun getFeeBasisPoints<CoinType>(lp_amount: u128, fee_basis_points: u128, tax_basis_points: u128, increment: bool): u128 acquires VaultStore, VaultFeeStore, VaultCoinStore {
        let vault_fee_store = borrow_global<VaultFeeStore>(@module_addr);

        if (!vault_fee_store.has_dynamic_fees) {
            fee_basis_points
        } else {
            let vault_coin_store = borrow_global<VaultCoinStore<CoinType>>(@module_addr);
            let initial_amount = vault_coin_store.lp_amount;
            let next_amount = if (increment) {
                initial_amount + lp_amount
            } else {
                if (lp_amount > initial_amount) {
                    0
                } else {
                    initial_amount - lp_amount
                }
            };

            let target_amount = getTargetLpAmount<CoinType>();
            if (target_amount == 0) { 
                fee_basis_points
            } else {
                let initial_diff = if (initial_amount > target_amount) {
                    initial_amount - target_amount
                } else {
                    target_amount - initial_amount
                };

                let next_diff = if (next_amount > target_amount) {
                    next_amount - target_amount
                } else {
                    target_amount - next_amount
                };

                // action improves relative asset balance
                if (next_diff < initial_diff) {
                    let rebate_bps = tax_basis_points * initial_diff / target_amount;
                    if (rebate_bps > fee_basis_points) {
                        0
                    } else {
                        fee_basis_points - rebate_bps
                    }
                } else {
                    let average_diff = (initial_diff + next_diff) / 2;
                    average_diff = if (average_diff > target_amount) {
                        target_amount
                    } else {
                        average_diff
                    };
                    let tax_bps = tax_basis_points * average_diff / target_amount;
                    fee_basis_points + tax_bps
                }
            }
        }
    }

    #[view]
    public fun get_total_supply_flp(): u128 {
        let maybe_supply = coin::supply<FLP>();
        let total_supply = if (option::is_some(&maybe_supply)) {
            *option::borrow(&maybe_supply)
        } else {
            0
        };
        (total_supply as u128)
    }

    fun getTargetLpAmount<CoinType>(): u128 acquires VaultStore, VaultCoinStore {
        let lp_supply = get_total_supply_flp();
        if (lp_supply == 0) { 
            0
        } else {
            let vault_coin_store = borrow_global<VaultCoinStore<CoinType>>(@module_addr);
            let weight = vault_coin_store.config.weight;
            
            let vault_store = borrow_global<VaultStore>(@module_addr);
            (weight  as u128) * lp_supply / (vault_store.total_coin_weights as u128)
        }
    }

    ///////////////////////////////
    /// VALIDATION
    ///////////////////////////////

    fun isWhitelisted<CoinType>(): CoinConfig acquires VaultCoinStore {
        assert!(exists<VaultCoinStore<CoinType>>(@module_addr), error::not_found(ENOT_WHITELISTED));
        let vault_coin_store = borrow_global<VaultCoinStore<CoinType>>(@module_addr);
        assert!(vault_coin_store.config.is_whitelist, error::invalid_state(ENOT_WHITELISTED));
        vault_coin_store.config
    }

    fun validateLongIncrease<CoinType>() acquires VaultCoinStore {
        let coin_config = isWhitelisted<CoinType>();
        assert!(!coin_config.is_stable, error::invalid_state(ESTABLE));
    }

    fun validateShortIncrease<CoinTypeCollateral, CoinTypeIndex>() acquires VaultCoinStore {
        let collateral_coin_config = isWhitelisted<CoinTypeCollateral>();
        let index_coin_config = isWhitelisted<CoinTypeIndex>();
        assert!(collateral_coin_config.is_stable, error::invalid_state(ENOT_STABLE));
        assert!(!index_coin_config.is_stable, error::invalid_state(ESTABLE));
        assert!(index_coin_config.is_shortable, error::invalid_state(ENOT_SHORTABLE));
    }

    ///////////////////////////////
    // TEST
    ///////////////////////////////
    #[test_only]
    public fun test_init_module(sender: &signer) {
        init_module(sender);
    }
}