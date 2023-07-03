module module_addr::fewcha_access {
    use std::signer;
    use std::error;

    const ENOT_GOV: u64 = 1;

    struct AccessStore has key {
        gov: address,
    }

    fun init_module(sender: &signer) {
        move_to(
            sender,
            AccessStore {
                gov: signer::address_of(sender),
            },
        );
    }

    ///////////////////////////////
    /// SECURITY FUNCTION
    ///////////////////////////////
    public entry fun update_gov (
        sender: &signer,
        new_gov: address
    ) acquires AccessStore {
        onlyGov(sender);
        let vault_store = borrow_global_mut<AccessStore>(@module_addr);
        vault_store.gov = new_gov;
    }

    ///////////////////////////////
    /// VALIDATION
    ///////////////////////////////
    public fun onlyGov(sender: &signer) acquires AccessStore {
        let vault_store = borrow_global<AccessStore>(@module_addr);
        let sender_addr = signer::address_of(sender);
        assert!(vault_store.gov == sender_addr, error::permission_denied(ENOT_GOV));
    }

    ///////////////////////////////
    // TEST
    ///////////////////////////////
    #[test_only]
    public fun test_init_module(sender: &signer) {
        init_module(sender);
    }
}