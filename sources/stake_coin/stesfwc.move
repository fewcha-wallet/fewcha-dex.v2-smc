module module_addr::stes_fwc {
    struct StesFWC {}

    public fun initialize(sender: &signer, resource_account: &signer) {
        module_addr::managed_coin::initialize<StesFWC>(
            sender,
            resource_account,
            b"Staked Fewcha Coin",
            b"stFWC",
            8,
            true,
        );
    }
}