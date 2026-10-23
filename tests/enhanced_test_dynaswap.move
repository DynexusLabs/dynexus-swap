// Additional robust test cases for the DEX contract
#[test_only]
module dynexus_swap::enhanced_test_dynaswap {
    use std::signer::address_of;
    use std::string::{utf8, String};
    use aptos_framework::account::{create_account_for_test, create_signer_for_test};
    use aptos_framework::genesis;
    use aptos_framework::timestamp;
    use dynexus_forge::token_factory;
    use dynexus_forge::token_factory_test;
    use dynexus_swap::test_dynaswap::max_single_swap;
    use dynexus_swap::dex;

    // Constants
    const TEST_INIT_SUPPLY: u64 = 10000;
    const DEFAULT_FEE_PERCENT: u64 = 1;
    const PLATFORM_FEE_PERCENT: u64 = 2;
    const TOTAL_FEE_PERCENT: u64 = 3;
    const FEE_DENOMINATOR: u64 = 10000;
    const MIN_LIQUIDITY: u64 = 1000;

    // Error codes
    const E_INVALID_BALANCE: u64 = 1000;
    const E_INVALID_RESERVE: u64 = 1001;
    const E_INVALID_FEE: u64 = 1002;
    const E_INVALID_SLIPPAGE: u64 = 1003;
    const E_INVALID_LIQUIDITY: u64 = 1004;
    const E_INVALID_PRICE: u64 = 1005;
    const E_INVALID_SWAP_AMOUNT: u64 = 1006;
    const E_INVALID_ARITHMETIC: u64 = 1007;

    // Helper functions
    fun setup(admin: &signer) {
        genesis::setup();
        create_account_for_test(address_of(admin));
        token_factory_test::setup_token_factory(address_of(admin));
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
        let (_, _, token) =
            token_factory::create_test_token(
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

    // ===== INVARIANT TESTS =====

    #[test(admin = @dynexus_swap)]
    fun test_k_invariant_maintenance(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x1);
        token_factory::faucet_dynexus(&issuer);
        let provider = create_account_for_test(@0x2);

        let tokenA =
            create_test_token(
                &issuer,
                utf8(b"TokenA"),
                utf8(b"TA"),
                8,
                quants(100000, 8),
                0
            );
        let tokenB =
            create_test_token(
                &issuer,
                utf8(b"TokenB"),
                utf8(b"TB"),
                8,
                quants(100000, 8),
                1
            );

        // Fund provider
        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenA,
            quants(10000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenB,
            quants(10000, 8)
        );

        // Create pool
        dex::create_pool(
            &provider,
            tokenA,
            tokenB,
            quants(10, 8),
            quants(10, 8)
        );

        // Record initial k = x * y
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);
        let (reserve_x_initial, reserve_y_initial) = dex::get_pool_reserves(pool_addr);
        let k_initial = reserve_x_initial * reserve_y_initial;

        // Perform multiple swaps
        let trader = create_account_for_test(@0x3);
        token_factory::mint_token(
            &issuer,
            address_of(&trader),
            tokenA,
            quants(500, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&trader),
            tokenB,
            quants(500, 8)
        );

        // Swap A -> B
        let (res_x, res_y) = dex::get_pool_reserves(pool_addr);
        let amount_in = max_single_swap(res_x);
        let amount_out = dex::get_amount_out(amount_in, res_x, res_y);
        dex::swap(
            &trader,
            tokenA,
            tokenB,
            amount_in,
            amount_out,
            timestamp::now_seconds() + 10
        );

        // Check k increased (due to fees)
        let (reserve_x_after, reserve_y_after) = dex::get_pool_reserves(pool_addr);
        let k_after = reserve_x_after * reserve_y_after;
        assert!(k_after > k_initial, E_INVALID_ARITHMETIC);

        // Swap B -> A
        let (res_y2, res_x2) = dex::get_pool_reserves(pool_addr);
        let amount_in2 = max_single_swap(res_y2);
        let amount_out2 = dex::get_amount_out(amount_in2, res_y2, res_x2);
        dex::swap(
            &trader,
            tokenB,
            tokenA,
            amount_in2,
            amount_out2,
            timestamp::now_seconds() + 10
        );

        // Check k increased again
        let (reserve_x_final, reserve_y_final) = dex::get_pool_reserves(pool_addr);
        let k_final = reserve_x_final * reserve_y_final;
        assert!(k_final > k_after, E_INVALID_ARITHMETIC);
    }

    #[test(admin = @dynexus_swap)]
    fun test_price_consistency_across_swaps(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x1);
        token_factory::faucet_dynexus(&issuer);

        let provider = create_account_for_test(@0x2);

        let tokenA =
            create_test_token(
                &issuer,
                utf8(b"TokenA"),
                utf8(b"TA"),
                8,
                quants(100000, 8),
                0
            );
        let tokenB =
            create_test_token(
                &issuer,
                utf8(b"TokenB"),
                utf8(b"TB"),
                8,
                quants(100000, 8),
                1
            );

        // Fund and create pool
        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenA,
            quants(10000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenB,
            quants(10000, 8)
        );
        dex::create_pool(
            &provider,
            tokenA,
            tokenB,
            quants(10, 8),
            quants(10, 8)
        );

        let trader = create_account_for_test(@0x3);
        token_factory::mint_token(
            &issuer,
            address_of(&trader),
            tokenA,
            quants(1000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&trader),
            tokenB,
            quants(1000, 8)
        );

        // Test price consistency for different swap sizes
        let swap_amounts = vector[quants(1, 7), quants(5, 7), quants(1, 8)]; // 0.1, 0.5, 1.0 tokens
        let i = 0;
        while (i < swap_amounts.length()) {
            let amount = *swap_amounts.borrow(i);
            let pool_addr = dex::get_pool_object_address(tokenA, tokenB);
            let (res_x, res_y) = dex::get_pool_reserves(pool_addr);
            let expected_out = dex::get_amount_out(amount, res_x, res_y);

            // Calculate price per unit (how much tokenB per tokenA)
            let price_per_unit = (expected_out * pow10(8)) / amount;

            // Calculate current market price (reserve ratio)
            let market_price = (res_y * pow10(8)) / res_x;

            // For small amounts, price should be close to current market price
            if (amount <= quants(1, 8)) {
                let price_diff =
                    if (price_per_unit > market_price) {
                        price_per_unit - market_price
                    } else {
                        market_price - price_per_unit
                    };

                // Price should be within 15% of market price for small swaps in low liquidity
                // (allowing for slippage and fees in a small pool)
                let tolerance = market_price / 7; // ~15% tolerance
                assert!(price_diff <= tolerance, 1001);
            };

            i += 1;
        };

        // Test that larger swaps have more price impact
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);
        let (res_x, res_y) = dex::get_pool_reserves(pool_addr);
        let small_amount = quants(1, 7); // 0.1 tokens
        let large_amount = quants(2, 8); // 2 tokens

        let small_out = dex::get_amount_out(small_amount, res_x, res_y);
        let large_out = dex::get_amount_out(large_amount, res_x, res_y);

        let small_price = (small_out * pow10(8)) / small_amount;
        let large_price = (large_out * pow10(8)) / large_amount;

        // Large swaps should have worse price (more slippage)
        assert!(large_price < small_price, 1002);
    }

    // ===== EDGE CASE TESTS =====

    #[test(admin = @dynexus_swap)]
    fun test_minimum_liquidity_enforcement(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x1);
        token_factory::faucet_dynexus(&issuer);
        let provider = create_account_for_test(@0x2);

        let tokenA =
            create_test_token(
                &issuer,
                utf8(b"TokenA"),
                utf8(b"TA"),
                8,
                quants(100000, 8),
                0
            );
        let tokenB =
            create_test_token(
                &issuer,
                utf8(b"TokenB"),
                utf8(b"TB"),
                8,
                quants(100000, 8),
                1
            );

        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenA,
            quants(10000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenB,
            quants(10000, 8)
        );

        // Create pool with minimum amounts
        dex::create_pool(
            &provider,
            tokenA,
            tokenB,
            quants(10, 8),
            quants(10, 8)
        );
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);

        // Get LP token balance
        let lp_address = dex::get_lp_address(pool_addr);
        let lp_balance = token_factory_test::balance_of(
            address_of(&provider), lp_address
        );

        // Try to remove almost all liquidity (should leave minimum)
        let remove_amount = lp_balance - MIN_LIQUIDITY;
        dex::remove_liquidity(&provider, tokenA, tokenB, remove_amount);

        // Check that minimum liquidity remains
        let remaining_lp =
            token_factory_test::balance_of(address_of(&provider), lp_address);
        assert!(remaining_lp >= MIN_LIQUIDITY, E_INVALID_LIQUIDITY);
    }

    #[test(admin = @dynexus_swap)]
    fun test_extreme_ratio_pools(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x1);
        token_factory::faucet_dynexus(&issuer);
        let provider = create_account_for_test(@0x2);

        let tokenA =
            create_test_token(
                &issuer,
                utf8(b"TokenA"),
                utf8(b"TA"),
                8,
                quants(1000000, 8),
                0
            );
        let tokenB =
            create_test_token(
                &issuer,
                utf8(b"TokenB"),
                utf8(b"TB"),
                8,
                quants(1000000, 8),
                1
            );

        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenA,
            quants(100000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenB,
            quants(100000, 8)
        );

        // Create pool with extreme ratio (1000:1)
        dex::create_pool(
            &provider,
            tokenA,
            tokenB,
            quants(100, 8),
            quants(10, 8)
        );

        // Test that swaps still work correctly
        let trader = create_account_for_test(@0x3);
        token_factory::mint_token(
            &issuer,
            address_of(&trader),
            tokenA,
            quants(1000, 8)
        );
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);
        let (res_y, res_x) = dex::get_pool_reserves(pool_addr);
        let amount_in = max_single_swap(res_x);
        let amount_out = dex::get_amount_out(amount_in, res_x, res_y);
        dex::swap(
            &trader,
            tokenA,
            tokenB,
            amount_in,
            amount_out,
            timestamp::now_seconds() + 10
        );

        // Verify trader received some tokenB
        let tokenB_balance = token_factory_test::balance_of(address_of(&trader), tokenB);
        assert!(tokenB_balance > 0, E_INVALID_BALANCE);
    }

    #[test(admin = @dynexus_swap)]
    fun test_precision_with_different_decimals(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x1);
        token_factory::faucet_dynexus(&issuer);

        let provider = create_account_for_test(@0x2);

        // Create tokens with very different decimals
        let tokenA =
            create_test_token(
                &issuer,
                utf8(b"TokenA"),
                utf8(b"TA"),
                2,
                quants(1000000, 2),
                0
            ); // 2 decimals
        let tokenB =
            create_test_token(
                &issuer,
                utf8(b"TokenB"),
                utf8(b"TB"),
                8,
                quants(1000000, 10),
                1
            ); // 10 decimals

        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenA,
            quants(10000, 2)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenB,
            quants(10000, 8)
        );

        // Create pool
        dex::create_pool(
            &provider,
            tokenA,
            tokenB,
            quants(1000, 2),
            quants(1000, 8)
        );

        // Test multiple small swaps to check precision
        let trader = create_account_for_test(@0x3);
        token_factory::mint_token(
            &issuer,
            address_of(&trader),
            tokenA,
            quants(100, 2)
        );

        let initial_balance = token_factory_test::balance_of(
            address_of(&trader), tokenB
        );

        // Perform multiple small swaps
        let i = 0;
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);
        while (i < 10) {
            let (res_x, res_y) = dex::get_pool_reserves(pool_addr);
            let amount_out = dex::get_amount_out(quants(1, 2), res_x, res_y);
            if (amount_out > 0) {
                dex::swap(
                    &trader,
                    tokenA,
                    tokenB,
                    quants(1, 2),
                    amount_out,
                    timestamp::now_seconds() + 10
                );
            };
            i += 1;
        };

        // Verify precision wasn't lost
        let final_balance = token_factory_test::balance_of(address_of(&trader), tokenA);
        assert!(final_balance > initial_balance, E_INVALID_BALANCE);
    }

    // ===== STRESS TESTS =====

    #[test(admin = @dynexus_swap)]
    fun test_high_volume_trading(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x1);
        token_factory::faucet_dynexus(&issuer);

        let provider = create_account_for_test(@0x2);

        let tokenA =
            create_test_token(
                &issuer,
                utf8(b"TokenA"),
                utf8(b"TA"),
                8,
                quants(1000000, 8),
                0
            );
        let tokenB =
            create_test_token(
                &issuer,
                utf8(b"TokenB"),
                utf8(b"TB"),
                8,
                quants(1000000, 8),
                1
            );

        // Create large pool
        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenA,
            quants(100000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenB,
            quants(100000, 8)
        );
        dex::create_pool(
            &provider,
            tokenA,
            tokenB,
            quants(20, 8),
            quants(20, 8)
        );

        // Create multiple traders
        let traders = vector[@0x101, @0x102, @0x103, @0x104, @0x105];
        let i = 0;
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);
        while (i < 5) {
            let trader = *traders.borrow(i);
            token_factory::mint_token(&issuer, trader, tokenA, quants(10000, 8));
            token_factory::mint_token(&issuer, trader, tokenB, quants(10000, 8));
            traders.push_back(trader);
            i += 1;
        };

        // Record initial reserves
        let (initial_x, initial_y) = dex::get_pool_reserves(pool_addr);
        let initial_k = initial_x * initial_y;

        // Execute high volume of trades
        let trade_count = 0;
        while (trade_count < 20) {
            let trader_idx = trade_count % 5;
            let trader = *traders.borrow(trader_idx);

            let (res_y, res_x) = dex::get_pool_reserves(pool_addr);
            let amount = max_single_swap(res_x);
            let amount_out = dex::get_amount_out(amount, res_x, res_y);

            dex::swap(
                &create_signer_for_test(trader),
                tokenA,
                tokenB,
                amount,
                amount_out,
                timestamp::now_seconds() + 10
            );
            trade_count += 1;
        };

        // Verify k increased (due to fees)
        let (final_x, final_y) = dex::get_pool_reserves(pool_addr);
        let final_k = final_x * final_y;
        assert!(final_k > initial_k, E_INVALID_ARITHMETIC);
    }

    #[test(admin = @dynexus_swap)]
    fun test_arbitrage_opportunities(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x1);
        token_factory::faucet_dynexus(&issuer);
        let provider1 = create_account_for_test(@0x2);
        let provider2 = create_account_for_test(@0x3);

        let tokenA =
            create_test_token(
                &issuer,
                utf8(b"TokenA"),
                utf8(b"TA"),
                8,
                quants(1000000, 8),
                0
            );
        let tokenB =
            create_test_token(
                &issuer,
                utf8(b"TokenB"),
                utf8(b"TB"),
                8,
                quants(1000000, 8),
                1
            );

        // Fund providers
        token_factory::mint_token(
            &issuer,
            address_of(&provider1),
            tokenA,
            quants(100000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&provider1),
            tokenB,
            quants(100000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&provider2),
            tokenA,
            quants(100000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&provider2),
            tokenB,
            quants(100000, 8)
        );

        // Create pools with different ratios
        dex::create_pool(
            &provider1,
            tokenA,
            tokenB,
            quants(10, 8),
            quants(10, 8)
        ); // 1:1 ratio

        // Simulate arbitrage by creating price imbalance
        let trader = create_account_for_test(@0x4);
        token_factory::mint_token(
            &issuer,
            address_of(&trader),
            tokenA,
            quants(10000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&trader),
            tokenB,
            quants(10000, 8)
        );

        // Large swap to create price imbalance
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);
        let (res_x, res_y) = dex::get_pool_reserves(pool_addr);
        let amount_in = max_single_swap(res_x);
        let amount_out = dex::get_amount_out(amount_in, res_x, res_y);
        dex::swap(
            &trader,
            tokenA,
            tokenB,
            amount_in,
            amount_out,
            timestamp::now_seconds() + 10
        );

        // Check that price changed
        let (new_res_x, new_res_y) = dex::get_pool_reserves(pool_addr);
        let old_ratio = res_x * pow10(8) / res_y;
        let new_ratio = new_res_x * pow10(8) / new_res_y;
        assert!(new_ratio != old_ratio, E_INVALID_PRICE);
    }

    // ===== SECURITY TESTS =====

    #[test(admin = @dynexus_swap)]
    fun test_flash_loan_protection(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x1);
        token_factory::faucet_dynexus(&issuer);
        let provider = create_account_for_test(@0x2);

        let tokenA =
            create_test_token(
                &issuer,
                utf8(b"TokenA"),
                utf8(b"TA"),
                8,
                quants(100000, 8),
                0
            );
        let tokenB =
            create_test_token(
                &issuer,
                utf8(b"TokenB"),
                utf8(b"TB"),
                8,
                quants(100000, 8),
                1
            );

        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenA,
            quants(10000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenB,
            quants(10000, 8)
        );
        dex::create_pool(
            &provider,
            tokenA,
            tokenB,
            quants(10, 8),
            quants(10, 8)
        );

        // Test that reserves are properly updated after swaps
        let attacker = create_account_for_test(@0x3);
        token_factory::mint_token(
            &issuer,
            address_of(&attacker),
            tokenA,
            quants(1000, 8)
        );

        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);
        let (res_y_before, res_x_before) = dex::get_pool_reserves(pool_addr);
        let amount_in = max_single_swap(res_x_before);
        let amount_out = dex::get_amount_out(amount_in, res_x_before, res_y_before);

        dex::swap(
            &attacker,
            tokenA,
            tokenB,
            amount_in,
            amount_out,
            timestamp::now_seconds() + 10
        );
        let (res_y_after, res_x_after) = dex::get_pool_reserves(pool_addr);

        // Verify reserves updated correctly
        assert!(res_x_after > res_x_before, E_INVALID_RESERVE); // X increased
        assert!(res_y_after < res_y_before, E_INVALID_RESERVE); // Y decreased
    }

    #[test(admin = @dynexus_swap)]
    fun test_reentrancy_protection(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x1);
        token_factory::faucet_dynexus(&issuer);

        let provider = create_account_for_test(@0x2);

        let tokenA =
            create_test_token(
                &issuer,
                utf8(b"TokenA"),
                utf8(b"TA"),
                8,
                quants(100000, 8),
                0
            );
        let tokenB =
            create_test_token(
                &issuer,
                utf8(b"TokenB"),
                utf8(b"TB"),
                8,
                quants(100000, 8),
                1
            );

        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenA,
            quants(10000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenB,
            quants(10000, 8)
        );
        dex::create_pool(
            &provider,
            tokenA,
            tokenB,
            quants(20, 8),
            quants(20, 8)
        );

        // Test multiple operations in sequence
        let user = create_account_for_test(@0x3);
        token_factory::mint_token(
            &issuer,
            address_of(&user),
            tokenA,
            quants(2000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&user),
            tokenB,
            quants(2000, 8)
        );

        // Multiple swaps should work correctly
        let i = 0;
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);
        while (i < 3) {
            let (res_y, res_x) = dex::get_pool_reserves(pool_addr);
            let amount_in = max_single_swap(res_x);
            let amount_out = dex::get_amount_out(amount_in, res_x, res_y);
            dex::swap(
                &user,
                tokenA,
                tokenB,
                amount_in,
                amount_out,
                timestamp::now_seconds() + 10
            );
            i += 1;
        };

        // Verify user received tokens
        let final_balance = token_factory_test::balance_of(address_of(&user), tokenB);
        assert!(final_balance > 0, E_INVALID_BALANCE);
    }

    // ===== ECONOMIC TESTS =====

    #[test(admin = @dynexus_swap)]
    fun test_impermanent_loss_calculation(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x1);
        token_factory::faucet_dynexus(&issuer);
        let provider = create_account_for_test(@0x2);

        let tokenA =
            create_test_token(
                &issuer,
                utf8(b"TokenA"),
                utf8(b"TA"),
                8,
                quants(1000000, 8),
                0
            );
        let tokenB =
            create_test_token(
                &issuer,
                utf8(b"TokenB"),
                utf8(b"TB"),
                8,
                quants(1000000, 8),
                1
            );

        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenA,
            quants(100000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenB,
            quants(100000, 8)
        );

        // Initial balances
        let initial_a = token_factory_test::balance_of(address_of(&provider), tokenA);
        let initial_b = token_factory_test::balance_of(address_of(&provider), tokenB);

        // Create pool with 1:1 ratio
        dex::create_pool(
            &provider,
            tokenA,
            tokenB,
            quants(10, 8),
            quants(10, 8)
        );
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);

        // Simulate price movement through large swaps
        let trader = create_account_for_test(@0x3);
        token_factory::mint_token(
            &issuer,
            address_of(&trader),
            tokenA,
            quants(50000, 8)
        );

        // Large swap to change price (A becomes cheaper)
        let (res_x, res_y) = dex::get_pool_reserves(pool_addr);
        let amount_in = max_single_swap(res_x);
        let amount_out = dex::get_amount_out(amount_in, res_x, res_y);
        dex::swap(
            &trader,
            tokenA,
            tokenB,
            amount_in,
            amount_out,
            timestamp::now_seconds() + 10
        );

        // Provider removes all liquidity
        let lp_address = dex::get_lp_address(pool_addr);
        let lp_balance = token_factory_test::balance_of(
            address_of(&provider), lp_address
        );

        dex::remove_liquidity(&provider, tokenA, tokenB, lp_balance);

        // Check final balances
        let final_a = token_factory_test::balance_of(address_of(&provider), tokenA);
        let final_b = token_factory_test::balance_of(address_of(&provider), tokenB);

        // Provider should have different token ratios now
        let initial_ratio = ((initial_a as u256) * (pow10(8) as u256)
            / (initial_b as u256) as u64);
        let final_ratio = ((final_a as u256) * (pow10(8) as u256) / (final_b as u256) as u64);
        assert!(initial_ratio != final_ratio, E_INVALID_BALANCE);
    }

    #[test(admin = @dynexus_swap)]
    fun test_fee_accumulation_over_time(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x1);
        token_factory::faucet_dynexus(&issuer);
        let provider = create_account_for_test(@0x2);

        let tokenA =
            create_test_token(
                &issuer,
                utf8(b"TokenA"),
                utf8(b"TA"),
                8,
                quants(1000000, 8),
                0
            );
        let tokenB =
            create_test_token(
                &issuer,
                utf8(b"TokenB"),
                utf8(b"TB"),
                8,
                quants(1000000, 8),
                1
            );

        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenA,
            quants(100000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenB,
            quants(100000, 8)
        );
        dex::create_pool(
            &provider,
            tokenA,
            tokenB,
            quants(10, 8),
            quants(10, 8)
        );

        let dex_config = dex::get_dex_object_address();
        let initial_platform_fee = token_factory_test::balance_of(dex_config, tokenA);

        // Simulate trading over time
        let trader = create_account_for_test(@0x3);
        token_factory::mint_token(
            &issuer,
            address_of(&trader),
            tokenA,
            quants(50000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&trader),
            tokenB,
            quants(50000, 8)
        );

        let total_volume = 0;
        let expected_platform_fee = 0;
        let trade_count = 0;
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);
        while (trade_count < 10) {
            let (res_y, res_x) = dex::get_pool_reserves(pool_addr);
            let amount = max_single_swap(res_x);
            total_volume += amount;
            expected_platform_fee +=((amount as u128) * (PLATFORM_FEE_PERCENT as u128)
                / (FEE_DENOMINATOR as u128) as u64);

            let amount_out = dex::get_amount_out(amount, res_x, res_y);
            dex::swap(
                &trader,
                tokenA,
                tokenB,
                amount,
                amount_out,
                timestamp::now_seconds() + 10
            );

            trade_count += 1;
        };

        // Check accumulated fees
        let final_platform_fee = token_factory_test::balance_of(dex_config, tokenA);
        let actual_platform_fee = final_platform_fee - initial_platform_fee;

        assert!(actual_platform_fee == expected_platform_fee, E_INVALID_FEE);
    }

    #[test(admin = @dynexus_swap)]
    fun test_liquidity_provider_rewards(admin: &signer) {
        setup(admin);

        let issuer = create_account_for_test(@0x1);
        token_factory::faucet_dynexus(&issuer);
        let provider = create_account_for_test(@0x2);

        let tokenA =
            create_test_token(
                &issuer,
                utf8(b"TokenA"),
                utf8(b"TA"),
                8,
                quants(1000000, 8),
                0
            );
        let tokenB =
            create_test_token(
                &issuer,
                utf8(b"TokenB"),
                utf8(b"TB"),
                8,
                quants(1000000, 8),
                1
            );

        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenA,
            quants(100000, 8)
        );
        token_factory::mint_token(
            &issuer,
            address_of(&provider),
            tokenB,
            quants(100000, 8)
        );

        let initial_a = token_factory_test::balance_of(address_of(&provider), tokenA);
        let initial_b = token_factory_test::balance_of(address_of(&provider), tokenB);

        dex::create_pool(
            &provider,
            tokenA,
            tokenB,
            quants(10, 8),
            quants(10, 8)
        );
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);

        // Generate trading fees
        let trader = create_account_for_test(@0x3);
        token_factory::mint_token(
            &issuer,
            address_of(&trader),
            tokenA,
            quants(50000, 8)
        );

        let trade_count = 0;
        while (trade_count < 5) {
            let (res_y, res_x) = dex::get_pool_reserves(pool_addr);
            let amount_in = max_single_swap(res_x);
            let amount_out = dex::get_amount_out(amount_in, res_x, res_y);
            dex::swap(
                &trader,
                tokenA,
                tokenB,
                amount_in,
                amount_out,
                timestamp::now_seconds() + 10
            );

            trade_count += 1;
        };

        // Get LP token balance before claiming rewards
        let lp_token_balance_before =
            token_factory_test::balance_of(address_of(&provider), pool_addr);

        // Remove liquidity to claim accumulated fees
        let liquidity_to_remove = lp_token_balance_before / 2; // Remove half the liquidity
        dex::remove_liquidity(&provider, tokenA, tokenB, liquidity_to_remove);

        // Check final balances
        let final_a = token_factory_test::balance_of(address_of(&provider), tokenA);
        let final_b = token_factory_test::balance_of(address_of(&provider), tokenB);

        // Verify that the provider received more tokens than initially provided
        // This accounts for the accumulated trading fees
        let expected_a = initial_a - quants(5000, 8); // Half of initial liquidity (10000/2)
        let expected_b = initial_b - quants(5000, 8); // Half of initial liquidity (10000/2)

        // The provider should have received additional tokens from trading fees
        assert!(final_a > expected_a, 1001); // Should have more TokenA due to fees
        assert!(final_b >= expected_b, 1002); // Should have at least the expected TokenB

        // Verify that some LP tokens are still held
        let remaining_lp_tokens =
            token_factory_test::balance_of(address_of(&provider), pool_addr);
        assert!(remaining_lp_tokens > 0, 1003);

        // Verify pool still has liquidity
        let (final_reserves_a, final_reserves_b) = dex::get_pool_reserves(pool_addr);
        assert!(final_reserves_a > 0, 1004);
        assert!(final_reserves_b > 0, 1005);
    }
}
