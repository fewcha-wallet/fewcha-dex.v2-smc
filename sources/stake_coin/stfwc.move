module module_addr::st_fwc {
    struct StFWC {}

    public fun initialize(sender: &signer, resource_account: &signer) {
        module_addr::managed_coin::initialize<StFWC>(
            sender,
            resource_account,
            b"Staked FWC",
            b"stFWC",
            8,
            true,
        );
    }
}