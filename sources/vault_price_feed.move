module module_addr::fewcha_vault_price_feed {
    use std::string;
    use std::error;

    use switchboard::aggregator;
    use switchboard::math;

    use aptos_std::event::{Self, EventHandle};
    use aptos_std::table::{Self, Table};
    use aptos_std::type_info;

    use aptos_framework::account;
    use module_addr::fewcha_access;

    const ENOT_REGISTERED: u64 = 1;

    struct UpdateAggregator has drop, store {
        coin_type: string::String,
        aggregator: address,
    }

    struct VaultPriceFeedStore has key {
        aggregators: Table<string::String, address>,

        // Events
        update_aggregator: EventHandle<UpdateAggregator>,
    }

    ///////////////////////////////
    /// Run when the module is published
    ///////////////////////////////
    fun init_module(sender: &signer) {
        move_to(
            sender,
            VaultPriceFeedStore {
                aggregators: table::new(),

                update_aggregator: account::new_event_handle<UpdateAggregator>(sender),
            },
        );
    }

    public entry fun update_aggregator<CoinType> (
        sender: &signer,
        _aggregator: address
    ) acquires VaultPriceFeedStore {
        fewcha_access::onlyGov(sender);
        let vault_price_feed_store = borrow_global_mut<VaultPriceFeedStore>(@module_addr);
        let coin_type = type_info::type_name<CoinType>();

        if (table::contains(&vault_price_feed_store.aggregators, coin_type)) {
            let aggregator_addr = table::borrow_mut(&mut vault_price_feed_store.aggregators, coin_type);
            *aggregator_addr = _aggregator;
        } else {
            table::add(&mut vault_price_feed_store.aggregators, coin_type, _aggregator);
        };

        event::emit_event(&mut vault_price_feed_store.update_aggregator, UpdateAggregator {
            coin_type,
            aggregator: _aggregator,
        });
    }

    public fun getPrice<CoinType>(): u128 acquires VaultPriceFeedStore {
        let vault_price_feed_store = borrow_global<VaultPriceFeedStore>(@module_addr);
        let coin_type = type_info::type_name<CoinType>();

        assert!(table::contains(&vault_price_feed_store.aggregators, coin_type), error::not_found(ENOT_REGISTERED));

        let aggregator_addr = table::borrow(&vault_price_feed_store.aggregators, coin_type);

        let latest_value = aggregator::latest_value(*aggregator_addr);
        let (value, _decimals, _neg) = math::unpack(latest_value);
        value
    }

    ///////////////////////////////
    // TEST
    ///////////////////////////////
    #[test_only]
    public fun test_init_module(sender: &signer) {
        init_module(sender);
    }
}