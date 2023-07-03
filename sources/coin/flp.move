module module_addr::flp {
    struct FLP {}

    public fun initialize(sender: &signer, resource_account: &signer) {
        module_addr::managed_coin::initialize<FLP>(
            sender,
            resource_account,
            b"FLP",
            b"FLP",
            8,
            true,
        );
    }
}