module module_addr::st_flp {
    struct StFLP {}

    public fun initialize(sender: &signer, resource_account: &signer) {
        module_addr::managed_coin::initialize<StFLP>(
            sender,
            resource_account,
            b"Staked FLP",
            b"stFLP",
            8,
            true,
        );
    }
}