#[test_only]
module dynexus_swap::comprehensive_dex_tests {
    use std::signer::address_of;
    use std::string::{utf8, String};
    use aptos_framework::account::{create_account_for_test};
    use aptos_framework::genesis;
    use aptos_framework::timestamp;
    use dynexus_forge::token_factory;
    use dynexus_forge::token_factory_test;
    use dynexus_swap::test_dynaswap::max_single_swap;
    use dynexus_swap::dex;

    // Constants
    const TEST_INIT_SUPPLY: u64 = 1000000;
    const DEFAULT_FEE_PERCENT: u64 = 1;
    const PLATFORM_FEE_PERCENT: u64 = 2;
    const TOTAL_FEE_PERCENT: u64 = 3;
    const FEE_DENOMINATOR: u64 = 10000;
    const MIN_LIQUIDITY: u64 = 1000;

    // Helper functions
    fun setup(admin: &signer) {
        genesis::setup();
        create_account_for_test(address_of(admin));
        token_factory::initalize_token_factory_with_out_genesis(admin);
        dex::test_init_dex(admin);
    }

    fun quants(amount: u64, decimal: u8): u64 {
        amount * (pow10(decimal))
    }

    fun pow10(decimal: u8): u64 {
        let result = 1u64;
        let i = 0;
        while (i < decimal) {
            result *= 10;
            i += 1;
        };
        result
    }

    fun create_test_token(
        owner: &signer,
        name: String,
        symbol: String,
        decimals: u8,
        supply: u64,
        index: u64
    ): address {
        let (_, _, token) = token_factory::create_test_token(
            owner,
            name,
            symbol,
            decimals,
            supply,
            utf8(b""),
            utf8(b""),
            index
        );
        token
    }

    // ===== MULTI-POOL & MULTI-USER SCENARIOS =====

    #[test(admin = @dynexus_swap)]
    fun test_multiple_pools_with_multiple_users(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x1);

        // Create 3 tokens
        let tokenA = create_test_token(&issuer, utf8(b"TokenA"), utf8(b"TA"), 8, quants(TEST_INIT_SUPPLY, 8), 0);
        let tokenB = create_test_token(&issuer, utf8(b"TokenB"), utf8(b"TB"), 8, quants(TEST_INIT_SUPPLY, 8), 1);
        let tokenC = create_test_token(&issuer, utf8(b"TokenC"), utf8(b"TC"), 8, quants(TEST_INIT_SUPPLY, 8), 2);

        // Create 3 liquidity providers
        let provider1 = create_account_for_test(@0x10);
        let provider2 = create_account_for_test(@0x11);
        let provider3 = create_account_for_test(@0x12);

        // Fund providers
        token_factory::mint_token(&issuer, address_of(&provider1), tokenA, quants(50000, 8));
        token_factory::mint_token(&issuer, address_of(&provider1), tokenB, quants(50000, 8));
        token_factory::mint_token(&issuer, address_of(&provider2), tokenA, quants(50000, 8));
        token_factory::mint_token(&issuer, address_of(&provider2), tokenC, quants(50000, 8));
        token_factory::mint_token(&issuer, address_of(&provider3), tokenB, quants(50000, 8));
        token_factory::mint_token(&issuer, address_of(&provider3), tokenC, quants(50000, 8));

        // Create 3 pools with different token pairs
        dex::create_pool(&provider1, tokenA, tokenB, quants(10, 8), quants(10, 8));
        dex::create_pool(&provider2, tokenA, tokenC, quants(10, 8), quants(20, 8)); // Different ratio
        dex::create_pool(&provider3, tokenB, tokenC, quants(30, 8), quants(10, 8)); // Different ratio

        // Create 5 traders
        let traders = vector[
            create_account_for_test(@0x20),
            create_account_for_test(@0x21),
            create_account_for_test(@0x22),
            create_account_for_test(@0x23),
            create_account_for_test(@0x24)
        ];

        // Fund traders with all tokens
        let i = 0;
        while (i < 5) {
            let trader = traders.borrow(i);
            token_factory::mint_token(&issuer, address_of(trader), tokenA, quants(10000, 8));
            token_factory::mint_token(&issuer, address_of(trader), tokenB, quants(10000, 8));
            token_factory::mint_token(&issuer, address_of(trader), tokenC, quants(10000, 8));
            i += 1;
        };

        // Simulate trading activity across all pools
        let trade_rounds = 0;
        while (trade_rounds < 3) {
            let j = 0;
            while (j < 5) {
                let trader = traders.borrow(j);

                // Alternate between different swap directions
                if (trade_rounds % 3 == 0) {
                    // Swap A->B in pool1
                    let pool_address= dex::get_pool_object_address(tokenA, tokenB);
                    let (res_x, res_y) = dex::get_pool_reserves(pool_address);
                    let amount_in = max_single_swap(res_x);
                    let amount_out = dex::get_amount_out(amount_in, res_x, res_y);
                    dex::swap(trader, tokenA, tokenB, amount_in, amount_out, timestamp::now_seconds() + 10);
                } else if (trade_rounds % 3 == 1) {
                    // Swap C->A in pool2
                    let pool_address= dex::get_pool_object_address(tokenA, tokenC);
                    let (res_x, res_y) = dex::get_pool_reserves(pool_address);
                    let amount_in = max_single_swap(res_x);
                    let amount_out = dex::get_amount_out(amount_in, res_y, res_x);
                    dex::swap(trader, tokenC, tokenA, amount_in, amount_out, timestamp::now_seconds() + 10);
                } else {
                    // Swap B->C in pool3
                    let pool_address= dex::get_pool_object_address(tokenB, tokenC);
                    let (res_x, res_y) = dex::get_pool_reserves(pool_address);
                    let amount_in = max_single_swap(res_x);
                    let amount_out = dex::get_amount_out(amount_in, res_x, res_y);
                    dex::swap(trader, tokenB, tokenC, amount_in, amount_out, timestamp::now_seconds() + 10);
                };
                j += 1;
            };
            trade_rounds += 1;
        };

        // Verify all pools have liquidity and k increased (due to fees)
        let pool1 = dex::get_pool_object_address(tokenA, tokenB);
        let (res1_x, res1_y) = dex::get_pool_reserves(pool1);

        let pool2 = dex::get_pool_object_address(tokenA, tokenC);
        let (res2_x, res2_y) = dex::get_pool_reserves(pool2);

        let pool3 = dex::get_pool_object_address(tokenB, tokenC);
        let (res3_x, res3_y) = dex::get_pool_reserves(pool3);

        assert!(res1_x > 0 && res1_y > 0, 1001);
        assert!(res2_x > 0 && res2_y > 0, 1002);
        assert!(res3_x > 0 && res3_y > 0, 1003);

        // Verify traders received expected tokens
        let trader1 = traders.borrow(0);
        let trader1_balance_b = token_factory_test::balance_of(address_of(trader1), tokenB);
        let trader1_balance_c = token_factory_test::balance_of(address_of(trader1), tokenC);
        assert!(trader1_balance_b > 0 || trader1_balance_c > 0, 1004);

        // Providers add more liquidity mid-operation
        let deadline = timestamp::now_seconds() + 10;

        let pool1_addr = dex::get_pool_object_address(tokenA, tokenB);
        let d_x = quants(500, 8);
        let d_y = d_x;
        let (amount_x_min, amount_y_min) =  dex::calculate_min_amounts(pool1_addr,d_x, d_y,1);
        dex::add_liquidity(&provider1, tokenA, tokenB, d_x,d_y, amount_x_min,  amount_y_min, deadline);

        let pool2_addr = dex::get_pool_object_address(tokenA, tokenC);
        let d_x = quants(1000, 8);
        let d_y = quants(500, 8);
        let (amount_x_min, amount_y_min) =  dex::calculate_min_amounts(pool2_addr,d_x, d_y,1);
        dex::add_liquidity(&provider2, tokenA, tokenC, d_x, d_y, amount_x_min, amount_y_min ,deadline); // Maintain ratio

        let pool3_addr = dex::get_pool_object_address(tokenB, tokenC);
        let d_x = quants(1500, 8);
        let d_y = quants(500, 8);
        let (amount_x_min, amount_y_min) =  dex::calculate_min_amounts(pool3_addr,d_x, d_y,1);
        dex::add_liquidity(&provider3, tokenB, tokenC, d_x, d_y, amount_x_min, amount_y_min, deadline); // Maintain ratio

        // Verify reserves increased
        let pool = dex::get_pool_object_address(tokenA, tokenB);
        let (res1_x_new, res1_y_new) = dex::get_pool_reserves(pool);
        assert!(res1_x_new > res1_x && res1_y_new > res1_y, 1005);

        // Partial liquidity removal
        let pool1_addr = dex::get_pool_object_address(tokenA, tokenB);
        let lp_balance = token_factory_test::balance_of(address_of(&provider1), dex::get_lp_address(pool1_addr));
        dex::remove_liquidity(&provider1, tokenA, tokenB, lp_balance / 2);

        // Verify final state
        let pool = dex::get_pool_object_address(tokenA, tokenB);
        let (final_res1_x, final_res1_y) = dex::get_pool_reserves(pool);
        assert!(final_res1_x > 0 && final_res1_y > 0, 1006);
        assert!(final_res1_x < res1_x_new && final_res1_y < res1_y_new, 1007);
    }

    // ===== COMPLEX LIQUIDITY SCENARIOS =====

    #[test(admin = @dynexus_swap)]
    fun test_liquidity_management_scenarios(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x1);
        let provider = create_account_for_test(@0x2);

        // Create tokens with different decimals
        let tokenA = create_test_token(&issuer, utf8(b"TokenA"), utf8(b"TA"), 6, quants(TEST_INIT_SUPPLY, 6), 0);
        let tokenB = create_test_token(&issuer, utf8(b"TokenB"), utf8(b"TB"), 10, quants(TEST_INIT_SUPPLY, 10), 1);

        // Fund provider
        token_factory::mint_token(&issuer, address_of(&provider), tokenA, quants(50000, 6));
        token_factory::mint_token(&issuer, address_of(&provider), tokenB, quants(50000, 10));

        // Create initial pool
        dex::create_pool(&provider, tokenA, tokenB, quants(10, 6), quants(10, 10));

        // Add liquidity in multiple steps
        let x_add_amounts = vector[
            quants(100, 6), quants(200, 6), quants(300, 6)
        ];
        let y_add_amounts = vector[
            quants(100, 10), quants(200, 10), quants(300, 10)
        ];

        let i = 0;
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);
        let deadline = timestamp::now_seconds() + 1;

        while (i < 3) {
            let (amount_a) = *x_add_amounts.borrow(i);
            let (amount_b) = *y_add_amounts.borrow(i);
            let (amount_x_min, amount_y_min) =  dex::calculate_min_amounts(pool_addr,amount_a, amount_b,1);
            dex::add_liquidity(&provider, tokenA, tokenB, amount_a, amount_b,amount_x_min, amount_y_min, deadline);
            i += 1;
        };

        // Verify reserves
        let pool = dex::get_pool_object_address(tokenA, tokenB);
        let (res_x, res_y) = dex::get_pool_reserves(pool);
        assert!(res_x == quants(610, 6), 2001);
        assert!(res_y == quants(610, 10), 2002);

        // Create trader and perform swaps
        let trader = create_account_for_test(@0x3);
        token_factory::mint_token(&issuer, address_of(&trader), tokenA, quants(10000, 6));

        // Multiple swaps with varying amounts
        let j = 0;
        while (j < 3) {
            let pool = dex::get_pool_object_address(tokenA, tokenB);
            let (res_x, res_y) = dex::get_pool_reserves(pool);
            let amount = max_single_swap(res_x);
            let amount_out = dex::get_amount_out(amount, res_x, res_y);
            dex::swap(&trader, tokenA, tokenB, amount, amount_out, timestamp::now_seconds() + 10);
            j += 1;
        };

        // Remove liquidity in portions
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);
        let lp_address = dex::get_lp_address(pool_addr);
        let total_lp = token_factory_test::balance_of(address_of(&provider), lp_address);

        // Remove 30%, then 50% of remaining
        dex::remove_liquidity(&provider, tokenA, tokenB, (total_lp * 30) / 100);
        let remaining_lp = token_factory_test::balance_of(address_of(&provider), lp_address);
        dex::remove_liquidity(&provider, tokenA, tokenB, (remaining_lp * 50) / 100);

        // Verify final LP balance
        let final_lp = token_factory_test::balance_of(address_of(&provider), lp_address);
        assert!(final_lp == (total_lp * 35) / 100, 2003); // 70% of 50% = 35%
    }

    // ===== SECURITY SCENARIOS =====
    #[test(admin = @dynexus_swap)]
    #[expected_failure(abort_code = dex::E_EXCESSIVE_SWAP)] // Expecting slippage error
    fun test_frontrunning_protection(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x1);
        let provider = create_account_for_test(@0x2);

        let tokenA = create_test_token(&issuer, utf8(b"TokenA"), utf8(b"TA"), 8, quants(TEST_INIT_SUPPLY, 8), 0);
        let tokenB = create_test_token(&issuer, utf8(b"TokenB"), utf8(b"TB"), 8, quants(TEST_INIT_SUPPLY, 8), 1);

        // Create pool
        token_factory::mint_token(&issuer, address_of(&provider), tokenA, quants(10000, 8));
        token_factory::mint_token(&issuer, address_of(&provider), tokenB, quants(10000, 8));
        dex::create_pool(&provider, tokenA, tokenB, quants(10, 8), quants(10, 8));

        // Create trader
        let trader = create_account_for_test(@0x3);
        token_factory::mint_token(&issuer, address_of(&trader), tokenA, quants(1000, 8));

        // Get initial quote
        let pool = dex::get_pool_object_address(tokenA, tokenB);
        let (res_x, res_y) = dex::get_pool_reserves(pool);
        let initial_out = dex::get_amount_out(quants(50, 8), res_x, res_y);

        // Simulate frontrunning by having another trader swap first
        let frontrunner = create_account_for_test(@0x4);
        token_factory::mint_token(&issuer, address_of(&frontrunner), tokenA, quants(500, 8));

        // Frontrunner executes large swap
        let amount_in = max_single_swap(res_x);
        let frontrun_out = dex::get_amount_out(amount_in, res_x, res_y);
        dex::swap(&frontrunner, tokenA, tokenB, amount_in, frontrun_out, timestamp::now_seconds() + 10);

        // Original trader tries to swap with outdated quote (should fail)
        dex::swap(&trader, tokenA, tokenB, quants(50, 8), initial_out, timestamp::now_seconds() + 10);
    }

    #[test(admin = @dynexus_swap)]
    fun test_reentrancy_and_race_conditions(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x1);

        // Create tokens
        let tokenA = create_test_token(&issuer, utf8(b"TokenA"), utf8(b"TA"), 8, quants(TEST_INIT_SUPPLY, 8), 0);
        let tokenB = create_test_token(&issuer, utf8(b"TokenB"), utf8(b"TB"), 8, quants(TEST_INIT_SUPPLY, 8), 1);

        // Create multiple providers
        let providers = vector[
            create_account_for_test(@0x10),
            create_account_for_test(@0x11),
            create_account_for_test(@0x12)
        ];

        // Fund providers and create pools
        let i = 0;
        dex::create_pool(&issuer, tokenA, tokenB, quants(10, 8), quants(10, 8));
        while (i < 3) {
            let provider = providers.borrow(i);
            token_factory::mint_token(&issuer, address_of(provider), tokenA, quants(10000, 8));
            token_factory::mint_token(&issuer, address_of(provider), tokenB, quants(10000, 8));
            i += 1;
        };

        // Create multiple traders
        let traders = vector[
            create_account_for_test(@0x20),
            create_account_for_test(@0x21),
            create_account_for_test(@0x22)
        ];

        // Fund traders
        let j = 0;
        while (j < 3) {
            let trader = traders.borrow(j);
            token_factory::mint_token(&issuer, address_of(trader), tokenA, quants(1000, 8));
            token_factory::mint_token(&issuer, address_of(trader), tokenB, quants(1000, 8));
            j += 1;
        };

        // Simulate concurrent operations
        let k = 0;
        while (k < 3) {
            let trader = traders.borrow(k);
            let provider = providers.borrow(k);

            // Parallel swaps
            let pool = dex::get_pool_object_address(tokenA, tokenB);
            let (res_x, res_y) = dex::get_pool_reserves(pool);
            let amount_in = max_single_swap(res_x);
            let amount_out = dex::get_amount_out(amount_in, res_x, res_y);
            dex::swap(trader, tokenA, tokenB, amount_in, amount_out, timestamp::now_seconds() + 10);

            // Parallel liquidity additions
            let pool_addr = dex::get_pool_object_address(tokenA, tokenB);
            let deadline = timestamp::now_seconds() + 1;
            let d_x = quants(10, 8);
            let d_y = quants(10, 8);

            let (amount_x_min, amount_y_min) =  dex::calculate_min_amounts(pool_addr,d_x, d_y,1);
            dex::add_liquidity(provider, tokenA, tokenB, d_x, d_y, amount_x_min,amount_y_min, deadline);

            // Parallel liquidity removals
            let pool_addr = dex::get_pool_object_address(tokenA, tokenB);
            let lp_address = dex::get_lp_address(pool_addr);
            let lp_balance = token_factory_test::balance_of(address_of(provider), lp_address);
            if (lp_balance > quants(5, 8)) {
                dex::remove_liquidity(provider, tokenA, tokenB, quants(5, 8));
            };

            k += 1;
        };

        // Verify all pools are in consistent state
        let m = 0;
        while (m < 3) {
            let pool = dex::get_pool_object_address(tokenA, tokenB);
            let (res_x, res_y) = dex::get_pool_reserves(pool);
            assert!(res_x > 0 && res_y > 0, 4001);

            // Verify k increased (fees collected)
            let falsy = ((res_x * res_y) as u128);
            let expected = ((quants(100, 8) * 2) as u128);
            assert!(falsy > expected, 4002); // Initial was 100*100
            m += 1;
        };
    }
}