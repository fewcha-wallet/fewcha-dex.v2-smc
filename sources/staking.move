module module_addr::fewcha_staking {
    use std::signer;
    use std::error;
    use std::option;

    use aptos_std::math128;
    use aptos_std::event::{Self, EventHandle};

    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;

    use module_addr::es_fwc::EsFWC;
    use module_addr::stes_fwc::{Self, StesFWC};
    use module_addr::flp::FLP;
    use module_addr::st_flp::{Self, StFLP};
    use module_addr::fwc::FWC;
    use module_addr::st_fwc::{Self, StFWC};
    use module_addr::managed_coin;
    use module_addr::fewcha_staking_distributor::{Self, DistributeCapability};

    struct StakingStore has key {
        signer_cap: account::SignerCapability,
        distribute_cap: DistributeCapability,

        claim_events: EventHandle<ClaimEvent>,
    }

    struct StakingReward<phantom StakedCoinType, phantom DistributedCoinType> has key {
        cumulative_reward_per_coin: u128,
    }

    struct StakingInfo<phantom StakedCoinType, phantom DistributedCoinType> has key {
        claimable_reward: u128,
        previous_cumulative_reward_per_coin: u128,
    }

    ///////////////////////////////
    /// Events
    ///////////////////////////////
    struct ClaimEvent has drop, store {
        sender_addr: address,
        amount: u64
    }

    const EINVALID_AMOUNT: u64 = 1;
    const EEXCEED_AMOUNT: u64 = 2;

    ///////////////////////////////
    /// Run when the module is published
    ///////////////////////////////
    fun init_module(sender: &signer) {
        let (resource_signer, resource_signer_cap) = account::create_resource_account(sender, b"staking");

        st_flp::initialize(sender, &resource_signer);
        st_fwc::initialize(sender, &resource_signer);
        stes_fwc::initialize(sender, &resource_signer);

        let distribute_cap = fewcha_staking_distributor::initialize(sender);

        move_to(
            sender,
            StakingStore {
                signer_cap: resource_signer_cap,
                distribute_cap: distribute_cap,

                claim_events: account::new_event_handle<ClaimEvent>(sender),
            },
        );

        // AptosCoin reward
        move_to(
            sender,
            StakingReward<StFLP, AptosCoin> {
                cumulative_reward_per_coin: 0,
            },
        );
        move_to(
            sender,
            StakingReward<StFWC, AptosCoin> { // stFWC + stesFWC
                cumulative_reward_per_coin: 0,
            },
        );

        // esFWC reward
        move_to(
            sender,
            StakingReward<StFLP, EsFWC> {
                cumulative_reward_per_coin: 0,
            },
        );
        move_to(
            sender,
            StakingReward<StFWC, EsFWC> {  // stFWC + stesFWC
                cumulative_reward_per_coin: 0,
            },
        );
    }

    //////////////////////////////////////////////////////////////
    // STAKE
    //////////////////////////////////////////////////////////////
    public entry fun stake_fwc(
        sender: &signer,
        amount: u128,
    ) acquires StakingStore, StakingReward, StakingInfo {
        // Stake FWC
        stake<FWC>(sender, amount);

        // Update staking reward
        updateRewards(sender);

        // Mint stFLP
        mintStakedCoin<StFWC>(sender, amount);

        // StakingInfo - Reward APT and EsFWC
        let signer_addr = signer::address_of(sender);
        if (!exists<StakingInfo<StFWC, AptosCoin>>(signer_addr)) {
            move_to(
                sender,
                StakingInfo<StFWC, AptosCoin> {
                    claimable_reward: 0,
                    previous_cumulative_reward_per_coin: 0,
                }
            );
        };
        if (!exists<StakingInfo<StFWC, EsFWC>>(signer_addr)) {
            move_to(
                sender,
                StakingInfo<StFWC, EsFWC> {
                    claimable_reward: 0,
                    previous_cumulative_reward_per_coin: 0,
                }
            );
        };
    }

    public entry fun stake_flp(
        sender: &signer,
        amount: u128,
    ) acquires StakingStore, StakingReward, StakingInfo {
        // Stake FLP
        stake<FLP>(sender, amount);

        // Update staking reward
        // Rewards: AptosCoin, EsFWC
        updateRewards(sender);

        // Receive stFLP
        mintStakedCoin<StFLP>(sender, amount);
        
        // StakingInfo - Reward APT and EsFWC
        let signer_addr = signer::address_of(sender);
        if (!exists<StakingInfo<StFLP, AptosCoin>>(signer_addr)) {
            move_to(
                sender,
                StakingInfo<StFLP, AptosCoin> {
                    claimable_reward: 0,
                    previous_cumulative_reward_per_coin: 0,
                }
            );
        };
        if (!exists<StakingInfo<StFLP, EsFWC>>(signer_addr)) {
            move_to(
                sender,
                StakingInfo<StFLP, EsFWC> {
                    claimable_reward: 0,
                    previous_cumulative_reward_per_coin: 0,
                }
            );
        };
    }

    public entry fun stake_esfwc(
        sender: &signer,
        amount: u128,
    ) acquires StakingStore, StakingReward, StakingInfo {
        // Stake esFWC
        stake<EsFWC>(sender, amount);

        // Update staking reward
        updateRewards(sender);

        // Receive stesFWC
        mintStakedCoin<StesFWC>(sender, amount);

        // StakingInfo - Reward APT and EsFWC
        // StFWC = StesFWC => So we are using same stake coin type
        let signer_addr = signer::address_of(sender);
        if (!exists<StakingInfo<StFWC, AptosCoin>>(signer_addr)) {
            move_to(
                sender,
                StakingInfo<StFWC, AptosCoin> {
                    claimable_reward: 0,
                    previous_cumulative_reward_per_coin: 0,
                }
            );
        };
        if (!exists<StakingInfo<StFWC, EsFWC>>(signer_addr)) {
            move_to(
                sender,
                StakingInfo<StFWC, EsFWC> {
                    claimable_reward: 0,
                    previous_cumulative_reward_per_coin: 0,
                }
            );
        };
    }

    fun stake<CoinType>(
        sender: &signer,
        amount: u128,
    ) acquires StakingStore {
        assert!(amount > 0, error::invalid_state(EINVALID_AMOUNT));

        // Transfer In
        let staking_store = borrow_global<StakingStore>(@module_addr);
        let resource_signer = account::create_signer_with_capability(&staking_store.signer_cap);
        let resource_signer_addr = signer::address_of(&resource_signer);

        if (!coin::is_account_registered<CoinType>(resource_signer_addr)){
            coin::register<CoinType>(&resource_signer);
        };
        coin::transfer<CoinType>(sender, resource_signer_addr, (amount as u64));

    }

    fun mintStakedCoin<CoinType>(
        sender: &signer,
        amount: u128
    ) acquires StakingStore {
        let sender_addr = signer::address_of(sender);
        if (!coin::is_account_registered<CoinType>(sender_addr)){
            coin::register<CoinType>(sender);
        };

        let staking_store = borrow_global<StakingStore>(@module_addr);
        let resource_signer = account::create_signer_with_capability(&staking_store.signer_cap);
        managed_coin::mint<CoinType>(
            &resource_signer,
            sender_addr,
            (amount as u64),
        );
    }

    //////////////////////////////////////////////////////////////
    // UNSTAKE
    //////////////////////////////////////////////////////////////
    public entry fun unstake_fwc(
        sender: &signer,
        amount: u128,
    ) acquires StakingStore, StakingReward, StakingInfo {
        updateRewards(sender);

        // Unstake FWC
        unstake<FWC>(sender, amount);

        // Burn stFWC
        burnStakedCoin<StFWC>(sender, amount);
    }

    public entry fun unstake_flp(
        sender: &signer,
        amount: u128,
    ) acquires StakingStore, StakingReward, StakingInfo {
        updateRewards(sender);

        // Unstake FLP
        unstake<FLP>(sender, amount);

        // Burn stFLP
        burnStakedCoin<StFLP>(sender, amount);
    }

    public entry fun unstake_esfwc(
        sender: &signer,
        amount: u128,
    ) acquires StakingStore, StakingReward, StakingInfo {
        updateRewards(sender);

        // Unstake esFWC
        unstake<EsFWC>(sender, amount);

        // Burn stesFWC
        burnStakedCoin<StesFWC>(sender, amount);
    }
    
    fun unstake<CoinType>(
        sender: &signer, 
        amount: u128
    ) acquires StakingStore {
        assert!(amount > 0, error::invalid_state(EINVALID_AMOUNT));

        // Transfer Out
        let staking_store = borrow_global<StakingStore>(@module_addr);
        let resource_signer = account::create_signer_with_capability(&staking_store.signer_cap);
        coin::transfer<CoinType>(&resource_signer, signer::address_of(sender), (amount as u64));
    }

    fun burnStakedCoin<CoinType>(
        sender: &signer,
        amount: u128
    ) acquires StakingStore {
        let staking_store = borrow_global<StakingStore>(@module_addr);
        let resource_signer = account::create_signer_with_capability(&staking_store.signer_cap);
        let resource_signer_addr = signer::address_of(&resource_signer);
        if (!coin::is_account_registered<CoinType>(resource_signer_addr)){
            coin::register<CoinType>(&resource_signer);
        };
        coin::transfer<CoinType>(sender, resource_signer_addr, (amount as u64));
        managed_coin::burn<CoinType>(
            &resource_signer,
            (amount as u64),
        );
    }

    //////////////////////////////////////////////////////////////
    // CLAIM
    //////////////////////////////////////////////////////////////

    #[view]
    public fun claimable_fwc_and_esfwc<DistributedCoinType>(sender_addr: address) : u64 acquires StakingReward, StakingInfo {
        let stake_amount = get_stake_amount_fwc_and_esfwc(sender_addr);
        let supply = get_total_staked_supply_fwc_and_esfwc();
        claimable<StFWC, DistributedCoinType>(sender_addr, stake_amount, supply)
    }

    #[view]
    public fun claimable_flp<DistributedCoinType>(sender_addr: address) : u64 acquires StakingReward, StakingInfo {
        let stake_amount = get_stake_amount_flp(sender_addr);
        let supply = get_total_staked_supply_flp();
        claimable<StFLP, DistributedCoinType>(sender_addr, stake_amount, supply)
    }

    fun claimable<StakedCoinType, DistributedCoinType>(
        sender_addr: address, 
        stake_amount: u128, 
        supply: u128
    ) : u64 acquires StakingReward, StakingInfo {
        if (!exists<StakingInfo<StakedCoinType, DistributedCoinType>>(sender_addr)) {
            (0 as u64)
        } else {
            let staking_info = borrow_global<StakingInfo<StakedCoinType, DistributedCoinType>>(sender_addr);

            if (stake_amount == 0) {
                (staking_info.claimable_reward as u64)
            } else {
                // Update from the previous since claimable store has not updated yet
                // We dont call updateRewards function because of not willing to change onchain state
                let pending_rewards = (fewcha_staking_distributor::pendingRewards<StakedCoinType, DistributedCoinType>() as u128) * precision();

                let staking_reward = borrow_global<StakingReward<StakedCoinType, DistributedCoinType>>(@module_addr);
                let reward_per_coin = pending_rewards / supply;
                let cumulative_reward_per_coin = staking_reward.cumulative_reward_per_coin + reward_per_coin;

                let account_reward = stake_amount * (cumulative_reward_per_coin - staking_info.previous_cumulative_reward_per_coin) / precision();

                let claimable_reward = staking_info.claimable_reward + account_reward;
                (claimable_reward as u64)
            }
        }
        
    }

    public entry fun claim<StakedCoinType, DistributedCoinType>(
        sender: &signer,
    ) acquires StakingStore, StakingReward, StakingInfo {
        updateRewards(sender);
        let sender_addr = signer::address_of(sender);

        let staking_info = borrow_global_mut<StakingInfo<StakedCoinType, DistributedCoinType>>(sender_addr);
        let amount = (staking_info.claimable_reward as u64);
        staking_info.claimable_reward = 0;

        if (amount > 0) {
            // Transfer Out
            let staking_store = borrow_global_mut<StakingStore>(@module_addr);
            let resource_signer = account::create_signer_with_capability(&staking_store.signer_cap);
            if (!coin::is_account_registered<DistributedCoinType>(sender_addr)){
                coin::register<DistributedCoinType>(sender);
            };
            coin::transfer<DistributedCoinType>(&resource_signer, sender_addr, amount);

            event::emit_event(&mut staking_store.claim_events, ClaimEvent {
                sender_addr,
                amount,
            });
        }
    }

    //////////////////////////////////////////////////////////////
    // Rewards
    //////////////////////////////////////////////////////////////

    fun precision(): u128 {
        math128::pow(10, 16) // Must be larger than staked coin supply
    }

    // esstFWC + stFWC
    #[view]
    public fun get_total_staked_supply_fwc_and_esfwc(): u128 {
        let maybe_supply = coin::supply<StFWC>();
        let st_fwc_supply = if (option::is_some(&maybe_supply)) {
            *option::borrow(&maybe_supply)
        } else {
            0
        };

        let maybe_supply = coin::supply<StesFWC>();
        let st_es_fwc_supply = if (option::is_some(&maybe_supply)) {
            *option::borrow(&maybe_supply)
        } else {
            0
        };

        let total_supply = st_fwc_supply + st_es_fwc_supply;
        (total_supply as u128)
    }

    #[view]
    public fun get_stake_amount_fwc_and_esfwc(sender_addr: address): u128 {
        let stake_amount_fwc = if (coin::is_account_registered<StFWC>(sender_addr)) {
            coin::balance<StFWC>(sender_addr)
        } else {
            0
        };
        let stake_amount_esfwc = if (coin::is_account_registered<StesFWC>(sender_addr)) {
            coin::balance<StesFWC>(sender_addr)
        } else {
            0
        };
        let stake_amount = stake_amount_fwc + stake_amount_esfwc;
        (stake_amount as u128)
    }

    fun update_reward_fwc_and_esfwc<DistributedCoinType>(
        sender: &signer,
    ) acquires StakingStore, StakingReward, StakingInfo {
        let total_supply = get_total_staked_supply_fwc_and_esfwc();
        let sender_addr = signer::address_of(sender);
        let stake_amount = get_stake_amount_fwc_and_esfwc(sender_addr);

        updateReward<StFWC, DistributedCoinType>(sender, total_supply, stake_amount);
    }

    // stFLP
    fun get_total_staked_supply_flp(): u128 {
        let maybe_supply = coin::supply<StFLP>();
        let total_supply = if (option::is_some(&maybe_supply)) {
            *option::borrow(&maybe_supply)
        } else {
            0
        };
        (total_supply as u128)
    }

    fun get_stake_amount_flp(sender_addr: address): u128 {
        let stake_amount = if (coin::is_account_registered<StFLP>(sender_addr)) {
            coin::balance<StFLP>(sender_addr)
        } else {
            0
        };
        (stake_amount as u128)
    }

    fun update_reward_flp<DistributedCoinType>(
        sender: &signer,
    ) acquires StakingStore, StakingReward, StakingInfo {
        let total_supply = get_total_staked_supply_flp();
        let sender_addr = signer::address_of(sender);
        let stake_amount = get_stake_amount_flp(sender_addr);

        updateReward<StFLP, DistributedCoinType>(sender, total_supply, stake_amount);
    }

    fun updateRewards(
        sender: &signer,
    ) acquires StakingStore, StakingReward, StakingInfo {
        update_reward_fwc_and_esfwc<AptosCoin>(sender);
        update_reward_fwc_and_esfwc<EsFWC>(sender);
        update_reward_flp<AptosCoin>(sender);
        update_reward_flp<EsFWC>(sender);
    }

    fun updateReward<StakedCoinType, DistributedCoinType>(
        sender: &signer,
        total_supply: u128,
        stake_amount: u128,
    ) acquires StakingStore, StakingReward, StakingInfo {
        let staking_store = borrow_global<StakingStore>(@module_addr);
        let resource_signer = account::create_signer_with_capability(&staking_store.signer_cap);
        let staking_reward = fewcha_staking_distributor::distribute<StakedCoinType, DistributedCoinType>(
            &resource_signer,
            &staking_store.distribute_cap
        );

        if (staking_reward > 0 && total_supply > 0 && stake_amount > 0) {
            let reward_per_coin = (staking_reward as u128) * precision() / total_supply;
            if (reward_per_coin > 0) {
                let staking_reward = borrow_global_mut<StakingReward<StakedCoinType, DistributedCoinType>>(@module_addr);
                staking_reward.cumulative_reward_per_coin = staking_reward.cumulative_reward_per_coin + reward_per_coin;

                let sender_addr = signer::address_of(sender);
                let staking_info = borrow_global_mut<StakingInfo<StakedCoinType, DistributedCoinType>>(sender_addr);

                let account_reward = stake_amount * (staking_reward.cumulative_reward_per_coin - staking_info.previous_cumulative_reward_per_coin) / precision();

                staking_info.claimable_reward = staking_info.claimable_reward + account_reward;
                staking_info.previous_cumulative_reward_per_coin = staking_reward.cumulative_reward_per_coin;
            }
        }
    }

    ///////////////////////////////
    // TEST
    ///////////////////////////////
    #[test_only]
    public fun test_init_module(sender: &signer) {
        init_module(sender);
    }
}