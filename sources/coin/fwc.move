module module_addr::fwc {
    struct FWC {}

    fun init_module(sender: &signer) {
        aptos_framework::managed_coin::initialize<FWC>(
            sender,
            b"Fewcha Coin",
            b"FWC",
            8,
            true,
        );
    }

    ///////////////////////////////
    // TEST
    ///////////////////////////////
    #[test_only]
    public fun test_init_module(sender: &signer) {
        init_module(sender);
    }
}