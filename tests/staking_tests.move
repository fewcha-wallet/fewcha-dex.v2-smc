#[test_only]
module module_addr::fewcha_staking_tests {
    use std::signer;
    use std::debug;
    use std::string;

    use aptos_framework::account;
    use aptos_framework::timestamp;
    use aptos_framework::block;
    use aptos_framework::coin;
    // use aptos_framework::aptos_coin::AptosCoin;

    use aptos_std::math64;

    use module_addr::fewcha_access;
    use module_addr::fewcha_staking;
    use module_addr::fwc::{Self, FWC};
    use module_addr::st_fwc::StFWC;
    use module_addr::stes_fwc::StesFWC;
    use module_addr::es_fwc::EsFWC;
    use module_addr::fewcha_staking_distributor;

    fun coinPrecision(): u64 {
        math64::pow(10, 8)
    }

    fun init_modules(sender: &signer) {
        fewcha_access::test_init_module(sender);
        fwc::test_init_module(sender);
        fewcha_staking::test_init_module(sender);
    }

    fun issue_coins(sender: &signer, receiver: &signer) {
        // Issue to receiver (FWC)
        let receiver_addr = signer::address_of(receiver);
        aptos_framework::managed_coin::register<FWC>(receiver);
        aptos_framework::managed_coin::mint<FWC>(
            sender,
            receiver_addr,
            1000 * coinPrecision(),
        );
    }

    #[test(
        gov = @module_addr,
        aptos_framework = @aptos_framework,

        staker1 = @0x100,
        staker2 = @0x101,
        staker3 = @0x102,
    )]
    fun test_happy_path(
        gov: &signer,
        aptos_framework: &signer,

        staker1: &signer, 
        staker2: &signer,
        staker3: &signer,
    ) {
        account::create_account_for_test(signer::address_of(gov));
        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(staker1));
        account::create_account_for_test(signer::address_of(staker2));
        account::create_account_for_test(signer::address_of(staker3));

        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test_secs(1);
        block::initialize_for_test(aptos_framework, 1);

        init_modules(gov);

        issue_coins(gov, staker1);
        issue_coins(gov, staker2);
        issue_coins(gov, staker3);

        // Update reward per seconds
        debug::print(&string::utf8(b"0. Update Staking FWC -> esFWC reward 1 coin per seconds"));
        fewcha_staking_distributor::set_coin_per_interval<StFWC, EsFWC>(gov, 1 * coinPrecision());

        // 1. Staker1 Stake 20 FWC -> Receive 20 stFWC
        debug::print(&string::utf8(b"1. Staker1 Stake 20 FWC -> Receive 20 stFWC"));
        fewcha_staking::stake_fwc(
            staker1,
            20 * (coinPrecision() as u128),
        );
        let stfwc_balance = coin::balance<StFWC>(signer::address_of(staker1));
        assert!(stfwc_balance == 20 * coinPrecision(), 1_1);
        let fwc_balance = coin::balance<FWC>(signer::address_of(staker1));
        assert!(fwc_balance == 980 * coinPrecision(), 1_2);

        // 2. Staker2 Stake 40 FWC -> Receive 40 stFWC
        debug::print(&string::utf8(b"2. Staker2 Stake 40 FWC -> Receive 40 stFWC"));
        fewcha_staking::stake_fwc(
            staker2,
            40 * (coinPrecision() as u128),
        );
        let stfwc_balance = coin::balance<StFWC>(signer::address_of(staker2));
        assert!(stfwc_balance == 40 * coinPrecision(), 2_1);
        let fwc_balance = coin::balance<FWC>(signer::address_of(staker2));
        assert!(fwc_balance == 960 * coinPrecision(), 2_2);

        // 3. Staker3 Stake 40 FWC -> Receive 40 stFWC
        debug::print(&string::utf8(b"3. Staker3 Stake 40 FWC -> Receive 40 stFWC"));
        fewcha_staking::stake_fwc(
            staker3,
            40 * (coinPrecision() as u128),
        );
        let stfwc_balance = coin::balance<StFWC>(signer::address_of(staker3));
        assert!(stfwc_balance == 40 * coinPrecision(), 3_1);
        let fwc_balance = coin::balance<FWC>(signer::address_of(staker3));
        assert!(fwc_balance == 960 * coinPrecision(), 3_2);

        // 4. Staker3 Check rewards after 1 hours - 3600 esFWC
        debug::print(&string::utf8(b"4. Check rewards after 1 hours - 3600 esFWC"));
        timestamp::fast_forward_seconds(3600); // 1 hour later
        let pendingRewards = fewcha_staking_distributor::pendingRewards<StFWC, EsFWC>();
        assert!(pendingRewards == 3600 * coinPrecision(), 4_1);

        let claimable = fewcha_staking::claimable_fwc_and_esfwc<EsFWC>(signer::address_of(staker3));
        // 40 holded StFWC / 100 total StFWC
        assert!(claimable == pendingRewards * 40 / 100, 4_2);

        // 5. Staker3 claim and earn 1440 esFWC
        debug::print(&string::utf8(b"5. Staker3 claim and earn 1440 esFWC"));
        fewcha_staking::claim<StFWC, EsFWC>(staker3);
        let esfwc_balance = coin::balance<EsFWC>(signer::address_of(staker3));
        assert!(esfwc_balance == claimable, 5_1);

        let claimable = fewcha_staking::claimable_fwc_and_esfwc<EsFWC>(signer::address_of(staker3));
        assert!(claimable == 0, 5_2);

        // 6. Staker3 stake 440 esFWC -> receive StesFWC
        debug::print(&string::utf8(b"6. Staker3 stake esFWC"));
        fewcha_staking::stake_esfwc(
            staker3,
            440 * (coinPrecision() as u128),
        );

        // 7. Staker3 Check rewards after 1 hours
        debug::print(&string::utf8(b"7. Check rewards after 1 hours - 6760 esFWC"));
        timestamp::fast_forward_seconds(3600); // 1 hour later
        let claimable = fewcha_staking::claimable_fwc_and_esfwc<EsFWC>(signer::address_of(staker3));
        // 40 stFWC + 440 stesFWC = 480 / 540 total = 0.88888888888
        let total_stfwc = fewcha_staking::get_total_staked_supply_fwc_and_esfwc();
        assert!(total_stfwc == 540 * (coinPrecision() as u128), 7_1);

        let stake_amount = coin::balance<StFWC>(signer::address_of(staker3)) + coin::balance<StesFWC>(signer::address_of(staker3));
        assert!(stake_amount == 480 * coinPrecision(), 7_2);

        let expect_claimable = 3600 * coinPrecision() * 480 / 540;
        let expect_claimable = expect_claimable - 1; // Because of some variable not divabled
        assert!(claimable == expect_claimable, 7_2);

        // 8. Staker2 claim and earn 170666666666
        // 1st hour = 1440 esFWC
        // 2nd hour = 3600 * 40/540 = 266.666666652 esFWC
        // total = 1706.66666665 esFWC
        debug::print(&string::utf8(b"8. Staker2 claim and earn 1706.66"));
        let claimable = fewcha_staking::claimable_fwc_and_esfwc<EsFWC>(signer::address_of(staker2));
        assert!(claimable == 170666666666, 8_2);

        fewcha_staking::claim<StFWC, EsFWC>(staker2);
        let esfwc_balance = coin::balance<EsFWC>(signer::address_of(staker2));
        assert!(esfwc_balance == claimable, 5_1);
    }
}