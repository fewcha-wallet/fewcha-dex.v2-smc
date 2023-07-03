module module_addr::fewcha_staking_distributor {
    use std::signer;

    use aptos_std::event::{Self, EventHandle};

    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::account;
    use aptos_framework::timestamp;

    use module_addr::fewcha_access;
    use module_addr::es_fwc::{Self, EsFWC};
    use module_addr::st_flp::StFLP;
    use module_addr::st_fwc::StFWC;

    struct DistributorSigner has key {
        signer_cap: account::SignerCapability,
    }

    struct Distribute has drop, store {
        distribute_amount: u64,
    }

    struct DistributorStore<phantom StakedCoinType, phantom DistributedCoinType> has key {
        coin_per_interval: u64,
        last_distribution_time: u64,

        distributes: EventHandle<Distribute>,
    }

    struct DistributeCapability has copy, store {}

    public fun initialize(sender: &signer): DistributeCapability {
        let (resource_signer, resource_signer_cap) = account::create_resource_account(sender, b"staking_distributor");

        es_fwc::initialize(sender, &resource_signer);

        move_to(
            sender, DistributorSigner {
                signer_cap: resource_signer_cap,
            }
        );

        // 4 distributor pools
        let now_seconds = timestamp::now_seconds();
        // stesFWC + stFWC - APT (30% swaping fee)
        move_to(
            sender, DistributorStore<StFWC, AptosCoin> {
                coin_per_interval: 0,
                last_distribution_time: now_seconds,

                distributes: account::new_event_handle<Distribute>(sender),
            }
        );
        // stFLP - APT (70% swaping fee)
        move_to(
            sender, DistributorStore<StFLP, AptosCoin> {
                coin_per_interval: 0,
                last_distribution_time: now_seconds,

                distributes: account::new_event_handle<Distribute>(sender),
            }
        );
        // stesFWC + stFWC - esFWC (50% block reward)
        move_to(
            sender, DistributorStore<StFWC, EsFWC> {
                coin_per_interval: 0,
                last_distribution_time: now_seconds,

                distributes: account::new_event_handle<Distribute>(sender),
            }
        );
        // stFLP - esFWC (50% block reward)
        move_to(
            sender, DistributorStore<StFLP, EsFWC> {
                coin_per_interval: 0,
                last_distribution_time: now_seconds,

                distributes: account::new_event_handle<Distribute>(sender),
            }
        );

        DistributeCapability {}
    }

    public entry fun set_coin_per_interval<StakedCoinType, DistributedCoinType>(sender: &signer, coin_per_interval: u64) acquires DistributorStore {
        fewcha_access::onlyGov(sender);
        let distributor_store = borrow_global_mut<DistributorStore<StakedCoinType, DistributedCoinType>>(@module_addr);
        distributor_store.coin_per_interval = coin_per_interval;
    }

    #[view]
    public fun pendingRewards<StakedCoinType, DistributedCoinType>(): u64 acquires DistributorStore {
        let now_seconds = timestamp::now_seconds();
        let distributor_store = borrow_global<DistributorStore<StakedCoinType, DistributedCoinType>>(@module_addr);

        let time_diff = now_seconds - distributor_store.last_distribution_time;
        distributor_store.coin_per_interval * time_diff
    }

    // StakedCoinType       = [stFWC, stFLP]
    // DistributedCoinType  = [esFWC, APT]
    public fun distribute<StakedCoinType, DistributedCoinType>(
        staking_resource_signer: &signer,
        _cap: &DistributeCapability,
    ): u64 acquires DistributorSigner, DistributorStore {

        let pending_reward = pendingRewards<StakedCoinType, DistributedCoinType>();
        if (pending_reward == 0) { 
            0
        } else {
            let distributor_store = borrow_global_mut<DistributorStore<StakedCoinType, DistributedCoinType>>(@module_addr);
            distributor_store.last_distribution_time = timestamp::now_seconds();

            let distributor_signer = borrow_global<DistributorSigner>(@module_addr);
            let resource_signer = account::create_signer_with_capability(&distributor_signer.signer_cap);
            let resource_signer_addr = signer::address_of(&resource_signer);

            let staking_resource_signer_addr = signer::address_of(staking_resource_signer);

            let distribute_amount = if (es_fwc::check_coin_type<DistributedCoinType>()) {
                if (!coin::is_account_registered<EsFWC>(staking_resource_signer_addr)){
                    coin::register<EsFWC>(staking_resource_signer);
                };
                // esFWC will mint exactly pending_reward
                module_addr::managed_coin::mint<EsFWC>(
                    &resource_signer,
                    staking_resource_signer_addr,
                    pending_reward,
                );
                pending_reward
            } else {
                // APT
                let balance = coin::balance<DistributedCoinType>(resource_signer_addr);
                let distribute_amount = if (pending_reward > balance) { 
                    balance
                } else {
                    pending_reward
                };

                coin::transfer<DistributedCoinType>(&resource_signer, staking_resource_signer_addr, distribute_amount);
                distribute_amount
            };


            event::emit_event(&mut distributor_store.distributes, Distribute {
                distribute_amount,
            });
            
            distribute_amount
        }
    }
}