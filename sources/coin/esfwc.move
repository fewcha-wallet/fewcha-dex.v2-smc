module module_addr::es_fwc {
    use aptos_std::type_info;

    struct EsFWC {}

    public fun initialize(sender: &signer, resource_account: &signer) {
        module_addr::managed_coin::initialize<EsFWC>(
            sender,
            resource_account,
            b"Escrowed Fewcha Coin",
            b"esFWC",
            8,
            true,
        );
    }

    #[view]
    public fun check_coin_type<CoinType>(): bool {
        type_info::type_name<CoinType>() == type_info::type_name<EsFWC>()
    }
}