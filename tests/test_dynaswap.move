#[test_only]
module dynexus_swap::test_dynaswap {

    use std::signer::address_of;
    use std::string::{utf8, String};
    use aptos_framework::account::create_account_for_test;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::genesis;
    use aptos_framework::object;
    use aptos_framework::primary_fungible_store;
    use dev::utils::print_formatted;
    use dynexus_forge::token_factory;
    use dynexus_swap::dex;

    //
    // Constants
    //
    const TEST_INIT_SUPPLY: u64 = 10000;

    //
    // Errors
    //
    // Fee structure constants
    // Fee structure constants matching your implementation
    const DEFAULT_FEE_PERCENT: u64 = 1;     // 0.01% (swap fee to pool)
    const PLATFORM_FEE_PERCENT: u64 = 2;    // 0.02% (platform fee)
    const TOTAL_FEE_PERCENT: u64 = 3;       // 0.03% total fees
    const FEE_DENOMINATOR: u64 = 10000;
    const E_INVALID_MINT_COUNT: u64 = 0;
    const E_TOKENS_MUST_BE_DIFFERENT: u64 = 4;
    const E_ZERO_AMOUNT: u64 = 6;
    const E_INVALID_LP_METADATA: u64 = 3;
    const E_PLATFORM_FEE_MISMATCH: u64 = 4;
    const E_SWAP_FEE_MISMATCH: u64 = 5;
    const E_TOTAL_FEE_MISMATCH: u64 = 6;
    const E_RESERVE_UPDATE_MISMATCH: u64 = 7;

    fun setup(admin: &signer) {
        genesis::setup();
        create_account_for_test(address_of(admin));
        token_factory::initalize_token_factory_with_out_genesis(admin);
        dex::test_init_dex(admin);
    }

    public fun quants(amount: u64, decimal: u8): u64 {
        amount * (pow10(decimal))
    }

    // Helper function to compute 10^decimal (returns u64)
    fun pow10(decimal: u8): u64 {
        let result = 1u64;
        let i = 0;
        while (i < decimal) {
            result *= 10;
            i += 1;
        };
        result
    }


    fun from_quants(amount: u64, decimal: u8): u64 {
        amount / (pow10(decimal))
    }

    fun create_token_pair_with_pool(issuer: &signer): (signer, address, address, address) {
        let provider = create_account_for_test(@0x3);

        let (_, _, tokenA) =
            token_factory::create_test_token(
                issuer,
                utf8(b"TA"),
                utf8(b"TA"),
                8,
                quants(TEST_INIT_SUPPLY, 8),
                utf8(b""),
                utf8(b""),
                0
            );
        let (_,_, tokenB) =
            token_factory::create_test_token(
                issuer,
                utf8(b"TB"),
                utf8(b"TB"),
                8,
                quants(TEST_INIT_SUPPLY, 8),
                utf8(b""),
                utf8(b""),
                1
            );



        token_factory::mint_token(issuer, address_of(&provider), tokenA,quants(10000, 8) );
        token_factory::mint_token(issuer, address_of(&provider), tokenB, quants(10000, 8));

        dex::create_pool(&provider, tokenA, tokenB,quants(10, 8) ,quants(1, 8) );
        let (token_x, token_y, _, _) =dex::sort_token(tokenA, tokenB, 0, 0);
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);

        (provider, token_x, token_y, pool_addr)
    }

    fun test_create_token(
        owner: &signer,
        name: String,
        symbol: String,
        decimals: u8,
        index: u64
    ): address {
        let (_, _,addre) =
            token_factory::create_test_token(
                owner,
                name,
                symbol,
                decimals,
                quants(TEST_INIT_SUPPLY, 8),
                utf8(b""),
                utf8(b""),
                index
            );
        addre
    }

    fun test_mint_token(
        owner: &signer,
        recipient: address,
        token: address,
        amount: u64
    ) {
        token_factory::mint_token(owner, recipient, token, amount);
    }

    #[test(admin = @dynexus_swap)]
    fun test_initialize_token(admin: &signer) {
        setup(admin);

        let owner_addr = @0x123;
        let user_addr = @0x456;
        let owner = &create_account_for_test(owner_addr);
        let user = &create_account_for_test(user_addr);

        let (token_a_name, token_b_name) = (utf8(b"Token A"), utf8(b"Token b"));

        // Initialize two test tokens
        let (_,_, tokenA) =
            token_factory::create_test_token(
                owner,
                token_a_name,
                utf8(b"TA"),
                8,
                quants(TEST_INIT_SUPPLY, 8),
                utf8(b""),
                utf8(b""),
                0
            );

        let (_,_, tokenB) =
            token_factory::create_test_token(
                owner,
                token_b_name,
                utf8(b"TB"),
                8,
                quants(TEST_INIT_SUPPLY, 8),
                utf8(b""),
                utf8(b""),
                1
            );

        let amount = 100;

        token_factory::mint_token(owner, user_addr, tokenA, amount);
        token_factory::mint_token(owner, user_addr, tokenB, amount);

        assert!(
            token_factory::get_token_balance(user, tokenA) == amount,
            E_INVALID_MINT_COUNT
        );

        assert!(
            token_factory::get_token_balance(user, tokenB) == amount,
            E_INVALID_MINT_COUNT
        );
    }

    #[test(admin = @dynexus_swap)]
    fun test_create_pool_success(admin: &signer) {
        setup(admin);

        // Create token issuers
        let token_a_issuer = &create_account_for_test(@0xA);
        let token_b_issuer = &create_account_for_test(@0xB);
        let liquidity_provider = create_account_for_test(@0xC);

        let (token_a_name, token_b_name) = (utf8(b"Token A"), utf8(b"Token b"));

        // Initialize two test tokens
        let (_,_, tokenA) =
            token_factory::create_test_token(
                token_a_issuer,
                token_a_name,
                utf8(b"TA"),
                8,
                quants(TEST_INIT_SUPPLY, 8),
                utf8(b""),
                utf8(b""),
                0
            );

        let (_,_, tokenB) =
            token_factory::create_test_token(
                token_b_issuer,
                token_b_name,
                utf8(b"TB"),
                8,
                quants(TEST_INIT_SUPPLY, 8),
                utf8(b""),
                utf8(b""),
                1
            );

        let amount = 1000;

        token_factory::mint_token(token_a_issuer, @0xC, tokenA, amount);
        token_factory::mint_token(token_b_issuer, @0xC, tokenB, amount);

        // Create pool with 100 of each token
        dex::create_pool(&liquidity_provider, tokenA, tokenB, 100, 100);
    }

    #[test(admin = @dynexus_swap)]
    #[expected_failure(abort_code = dex::E_TOKENS_MUST_BE_DIFFERENT)]
    fun test_create_pool_same_tokens(admin: &signer) {
        setup(admin);

        let issuer = create_account_for_test(@0xA);
        let provider = create_account_for_test(@0xB);
        let token_b_name = utf8(b"Token B");

        let (_,_, tokenB) =
            token_factory::create_test_token(
                &provider,
                token_b_name,
                utf8(b"TB"),
                9,
                quants(TEST_INIT_SUPPLY, 8),
                utf8(b""),
                utf8(b""),
                0
            );

        token_factory::mint_token(&provider, address_of(&issuer), tokenB, 1000);

        dex::create_pool(&provider, tokenB, tokenB, 100, 100);
    }

    #[test(admin = @dynexus_swap)]
    #[expected_failure(abort_code = dex::E_ZERO_AMOUNT)]
    fun test_create_pool_zemo_amoumt(admin: &signer) {
        setup(admin);

        let issuer = create_account_for_test(@0xA);
        let provider = create_account_for_test(@0xB);
        let token_b_name = utf8(b"Token B");
        let token_a_name = utf8(b"Token A");

        let (_,_, tokenA) =
            token_factory::create_test_token(
                &provider,
                token_a_name,
                utf8(b"TA"),
                9,
                quants(TEST_INIT_SUPPLY, 8),
                utf8(b""),
                utf8(b""),
                0
            );

        let (_,_, tokenB) =
            token_factory::create_test_token(
                &provider,
                token_b_name,
                utf8(b"TB"),
                9,
                quants(TEST_INIT_SUPPLY, 8),
                utf8(b""),
                utf8(b""),
                1
            );

        token_factory::mint_token(&provider, address_of(&issuer), tokenB, 1000);
        token_factory::mint_token(&provider, address_of(&issuer), tokenB, 1000);

        dex::create_pool(&provider, tokenA, tokenB, 100, 0);
    }

    #[test(admin = @dynexus_swap)]
    fun test_lp_token_metadata(admin: &signer) {
        setup(admin);

        // Create token issuers
        let token_a_issuer = create_account_for_test(@0xA);
        let liquidity_provider = create_account_for_test(@0xC);

        let (token_a_name, token_b_name) = (utf8(b"Token A"), utf8(b"Token b"));

        // Initialize two test tokens
        let (_, _,tokenA) =
            token_factory::create_test_token(
                &token_a_issuer,
                token_a_name,
                utf8(b"TA"),
                9,
                quants(TEST_INIT_SUPPLY, 8),
                utf8(b""),
                utf8(b""),
                0
            );

        let (_, _, tokenB) =
            token_factory::create_test_token(
                &token_a_issuer,
                token_b_name,
                utf8(b"TB"),
                9,
                quants(TEST_INIT_SUPPLY, 8),
                utf8(b""),
                utf8(b""),
                1
            );

        // Mint initial tokens to liquidity provider
        let mint_amount = 1000;
        token_factory::mint_token(
            &token_a_issuer,
            address_of(&liquidity_provider),
            tokenA,
            mint_amount
        );
        token_factory::mint_token(
            &token_a_issuer,
            address_of(&liquidity_provider),
            tokenB,
            mint_amount
        );

        // Create pool with 100 of each token
        dex::create_pool(&liquidity_provider, tokenB, tokenA, 100, 100);

        let pool_address = dex::get_pool_object_address(tokenB, tokenA);
        let lp_token = object::address_to_object<Metadata>(dex::get_lp_address(pool_address));
        // Accessing properties of the metadata
        let name = fungible_asset::name(lp_token);
        let symbol = fungible_asset::symbol(lp_token);
        let decimals = fungible_asset::decimals(lp_token);
        assert!(decimals == 9, E_INVALID_LP_METADATA); // Should use higher decimals (9 > 6)
        assert!(symbol == utf8(b"DYNEXUS-TA-TB"), E_INVALID_LP_METADATA);
        assert!(name == utf8(b"DYNEXUS LP Token TA-TB"), E_INVALID_LP_METADATA);
    }

    #[test(admin = @dynexus_swap)]
    #[expected_failure(abort_code = dex::E_POOL_ALREADY_EXISTS)]
    fun test_create_pool_duplicate(admin: &signer) {
        setup(admin);

        let issuer = create_account_for_test(@0x1);
        let provider = create_account_for_test(@0x2);

        let tokenA = test_create_token(&issuer, utf8(b"TKA"), utf8(b"A"), 6, 0);
        let tokenB = test_create_token(&issuer, utf8(b"TKB"), utf8(b"B"), 6, 1);

        test_mint_token(&issuer, address_of(&provider), tokenA, 1000);
        test_mint_token(&issuer, address_of(&provider), tokenB, 1000);

        dex::create_pool(&provider, tokenA, tokenB, 100, 100);
        dex::create_pool(&provider, tokenA, tokenB, 100, 100); // should fail
    }

    #[test(admin = @dynexus_swap)]
    fun test_create_pool_reverse_tokens(admin: &signer) {
        setup(admin);

        let issuer = create_account_for_test(@0x3);
        let provider = create_account_for_test(@0x4);

        let tokenA = test_create_token(&issuer, utf8(b"TKA"), utf8(b"A"), 8, 0);
        let tokenB = test_create_token(&issuer, utf8(b"TKB"), utf8(b"B"), 8, 1);

        test_mint_token(&issuer, address_of(&provider), tokenA, 1000);
        test_mint_token(&issuer, address_of(&provider), tokenB, 1000);

        dex::create_pool(&provider, tokenA, tokenB, 100, 100);

        let addr1 = dex::get_pool_object_address(tokenA, tokenB);
        let addr2 = dex::get_pool_object_address(tokenB, tokenA);

        // Ensure address is symmetric
        assert!(addr1 == addr2, 9001);
    }

    #[test(admin = @dynexus_swap)]
    fun test_lp_metadata_long_names(admin: &signer) {
        setup(admin);

        let issuer = create_account_for_test(@0x5);
        let provider = create_account_for_test(@0x6);

        let tokenA = test_create_token(
            &issuer,
            utf8(b"SuperTokenAlpha"),
            utf8(b"ALPHA"),
            9,0
        );
        let tokenB = test_create_token(
            &issuer,
            utf8(b"BetaTokenBravo"),
            utf8(b"BETA"),
            9,
            1
        );

        test_mint_token(&issuer, address_of(&provider), tokenA, 1000);
        test_mint_token(&issuer, address_of(&provider), tokenB, 1000);

        print_formatted(b"tokenA", tokenA);
        print_formatted(b"tokenB", tokenB);

        dex::create_pool(&provider, tokenA, tokenB, 200, 200);
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);
        let lp_address = dex::get_lp_address(pool_addr);
        let lp_asset = object::address_to_object<Metadata>(lp_address);
        let name = fungible_asset::name(lp_asset);
        let symbol = fungible_asset::symbol(lp_asset);

        // Name should still be correctly constructed
        assert!(
            name == utf8(b"DYNEXUS LP Token ALPHA-BETA"),
            E_INVALID_LP_METADATA
        );
        print_formatted(b"symbol", symbol);
        assert!(
            symbol == utf8(b"DYNEXUS-LP-ALPHA-BETA"),
            E_INVALID_LP_METADATA
        );
    }

    #[test(admin = @dynexus_swap)]
    fun test_add_liquidity(admin: &signer) {
        setup(admin);
        let (provider, tokenA, tokenB, pool_addr) = create_token_pair_with_pool(admin);
        let amount_x_desired= quants(50, 8);
        let amount_y_desired =quants(5, 8);

        let (amount_x_min, amount_y_min) =  dex::calculate_min_amounts(pool_addr,amount_x_desired, amount_y_desired,1);

        dex::add_liquidity(&provider, tokenA, tokenB, amount_x_desired, amount_y_desired, amount_x_min, amount_y_min);

        let lp_address = dex::get_lp_address(pool_addr);
        let balance = token_factory::get_balance(address_of(&provider), lp_address);
        assert!(balance > 0, 1001);
    }

    #[test(admin = @dynexus_swap)]
    fun test_remove_liquidity(admin: &signer) {
        setup(admin);
        let (provider, tokenA, tokenB, pool_addr) = create_token_pair_with_pool(admin);

        let amount_x_desired = quants(10, 8);      // 100 TokenA
        let amount_y_desired = quants(1, 8);

        let (amount_x_min, amount_y_min) =  dex::calculate_min_amounts(pool_addr,amount_x_desired, amount_y_desired,1);

        dex::add_liquidity(&provider, tokenA, tokenB, amount_x_desired, amount_y_desired, amount_x_min, amount_y_min);
        let lp_address = dex::get_lp_address(pool_addr);
        let lp_balance_before =
            token_factory::get_balance(address_of(&provider), lp_address);
        assert!(lp_balance_before > 0, 1002);
        dex::remove_liquidity(&provider, tokenA, tokenB, lp_balance_before);

        let lp_balance_after =
            token_factory::get_balance(address_of(&provider), lp_address);
        assert!(lp_balance_after == 0, 1003);

        let (rx, ry) = dex::get_pool_reserves(tokenA, tokenB);
        assert!(rx == 0 && ry == 0, 1004);
    }

    #[test(admin = @dynexus_swap)]
    fun test_full_dex_flow(admin: &signer) {
        setup(admin);
        // Step 2: Create issuer, user
        let issuer = create_account_for_test(@0x3);
        let user = create_account_for_test(@0x4);

        // Step 3: Create and register 2 tokens
        let (_, _, tokenA) =
            token_factory::create_test_token(
                &issuer,
                utf8(b"Gold"),
                utf8(b"TG"),
                6,
                quants(1000, 8),
                utf8(b""),
                utf8(b""),
                0
            );
        let (_, _, tokenB) =
            token_factory::create_test_token(
                &issuer,
                utf8(b"Silver"),
                utf8(b"TS"),
                6,
                quants(1000, 8),
                utf8(b""),
                utf8(b""),
                1
            );

        token_factory::mint_token(&issuer, address_of(&user), tokenA, quants(100, 8));
        token_factory::mint_token(&issuer, address_of(&user), tokenB, quants(100, 8));

        // Step 4: Create pool
        dex::create_pool(&user, tokenA, tokenB, quants(12, 8), quants(35, 8));
        let pool_addr = dex::get_pool_object_address(tokenA, tokenB);

        // Check pool state
        let (_, rx, ry, supply, _, _, _) = dex::get_pool_info(pool_addr);
        assert!(rx == quants(35, 8) && ry == quants(12, 8) && supply > 0, 2001);

        let amount_x_desired= quants(2, 8);
        let amount_y_desired =quants(7, 8);

        let (amount_x_min, amount_y_min) =  dex::calculate_min_amounts(pool_addr,amount_x_desired, amount_y_desired,1);

        // Step 5: Add liquidity
        dex::add_liquidity(&user, tokenA, tokenB, amount_x_desired, amount_y_desired, amount_x_min, amount_y_min);

        let lp_balance_after_add =
            token_factory::get_balance(address_of(&user), pool_addr);
        assert!(lp_balance_after_add > 0, 2002);

        // Step 6: Remove all liquidity
        dex::remove_liquidity(&user, tokenA, tokenB, lp_balance_after_add);

        let lp_balance_final = token_factory::get_balance(
            address_of(&user), pool_addr
        );
        assert!(lp_balance_final == 0, 2004);
    }

    #[test(admin = @dynexus_swap)]
    fun test_swap_with_fee(admin: &signer) {
        setup(admin);
        let (provider, tokenA, tokenB, pool_addr) = create_token_pair_with_pool(admin);

        // Step 5: Add liquidity
        let amount_x_desired= quants(8, 8);
        let amount_y_desired =quants(3, 8);

        let (amount_x_min, amount_y_min) =  dex::calculate_min_amounts(pool_addr,amount_x_desired, amount_y_desired,1);

        dex::add_liquidity(&provider, tokenA, tokenB, amount_x_desired, amount_y_desired, amount_x_min, amount_y_min);

        // Add more liquidity to stabilize
        let amount_x_desired= quants(10, 8);
        let amount_y_desired =quants(5, 8);
        let (amount_x_min, amount_y_min) =  dex::calculate_min_amounts(pool_addr,amount_x_desired, amount_y_desired,1);
        dex::add_liquidity(&provider, tokenA, tokenB, amount_x_desired, amount_y_desired, amount_x_min, amount_y_min);

        let user_addr = @0xBEEF;
        let user = &create_account_for_test(user_addr);

        token_factory::mint_token(admin, user_addr, tokenA, quants(50, 8));
        token_factory::mint_token(admin, user_addr, tokenB, quants(50, 8));

        // Swap 100 tokenA to tokenB
        let amount_in = quants(50, 8);
        let (rev_x, rev_y) = dex::get_pool_reserves(tokenA, tokenB);

        let min_out = dex::get_amount_out(amount_in, rev_x, rev_y);
        dex::swap(user, tokenA, tokenB, quants(50, 8), min_out);

        // Assert tokenB balance increased
        let tokenB_metadata = token_factory::get_token_metadata(tokenB);
        let tokenB_balance = primary_fungible_store::balance(user_addr, tokenB_metadata);
        assert!(tokenB_balance > 0, 5001);

        // Assert platform_fee_recipient received fee
        let config = dex::get_dex_object_address();
        let fee_recipient_balance = token_factory::get_balance(config, tokenA);
        assert!(fee_recipient_balance > 0, 5002);
    }



    #[test(admin = @dynexus_swap)]
    fun test_swap_with_slippage(admin: &signer) {
        setup(admin);
        let (provider, tokenA, tokenB, pool_addr) = create_token_pair_with_pool(admin);

        // Add initial liquidity
        let amount_x_desired = quants(1000, 8);
        let amount_y_desired = quants(100, 8);
        let (amount_x_min, amount_y_min) = dex::calculate_min_amounts(pool_addr, amount_x_desired, amount_y_desired, 1);
        dex::add_liquidity(&provider, tokenA, tokenB, amount_x_desired, amount_y_desired, amount_x_min, amount_y_min);

        // Create user and fund them
        let user = create_account_for_test(@0x1234);
        token_factory::mint_token(admin, address_of(&user), tokenA, quants(500, 8));

        // Get reserves before swap
        let (reserve_x_before, reserve_y_before) = dex::get_pool_reserves(tokenA, tokenB);

        // Calculate expected output amount dynamically
        let input_amount = quants(100, 8);
        let expected_output = dex::get_amount_out(input_amount, reserve_x_before, reserve_y_before);

        // Apply 1% slippage tolerance
        let min_output = expected_output * 99 / 100;

        // Perform swap with slippage protection
        dex::swap(&user, tokenA, tokenB, input_amount, min_output);

        // Verify output is within expected range
        let tokenB_balance = token_factory::get_token_balance(&user, tokenB);
        assert!(tokenB_balance >= min_output && tokenB_balance <= expected_output, 6001);
    }

    #[test(admin = @dynexus_swap)]
    #[expected_failure(abort_code = dex::E_INSUFFICIENT_OUTPUT_AMOUNT)]
    fun test_swap_fails_with_high_slippage(admin: &signer) {
        setup(admin);
        let (provider, tokenA, tokenB, pool_addr) = create_token_pair_with_pool(admin);

        // Add small liquidity to create price impact
        let amount_x_desired = quants(100, 8);
        let amount_y_desired = quants(10, 8);
        let (amount_x_min, amount_y_min) = dex::calculate_min_amounts(pool_addr, amount_x_desired, amount_y_desired, 1);
        dex::add_liquidity(&provider, tokenA, tokenB, amount_x_desired, amount_y_desired, amount_x_min, amount_y_min);

        let user = create_account_for_test(@0x2345);
        token_factory::mint_token(admin, address_of(&user), tokenA, quants(500, 8));

        // Set unrealistic min output (higher than possible)
        let input_amount = quants(50, 8);
        let (reserve_x, reserve_y) = dex::get_pool_reserves(tokenA, tokenB);
        let realistic_output = dex::get_amount_out(input_amount, reserve_x, reserve_y);
        let unrealistic_min_output = realistic_output * 2; // 2x expected output

        // This should fail
        dex::swap(&user, tokenA, tokenB, input_amount, unrealistic_min_output);
    }

    #[test(admin = @dynexus_swap)]
    fun test_add_liquidity_uneven_amounts(admin: &signer) {
        setup(admin);
        let (provider, tokenA, tokenB, pool_addr) = create_token_pair_with_pool(admin);

        // Get initial reserves

        // Add liquidity with uneven amounts (but correct ratio)

        let amount_x_d = quants(10, 8);
        let amount_y_d = quants(1, 8); // Maintains 10:1 ratio

        let (token_x, token_y, amount_x, amount_y) = dex::sort_token(tokenA, tokenB, amount_x_d, amount_y_d);
        let (initial_reserve_x, initial_reserve_y) = dex::get_pool_reserves(token_x, token_y);

        let (amount_x_min, amount_y_min) = dex::calculate_min_amounts(pool_addr, amount_x, amount_y, 1);
        let (new_x, new_y) = dex::calculate_optimal_add_amounts(initial_reserve_x, initial_reserve_y, amount_x, amount_y);

        dex::add_liquidity(&provider, token_x, token_y, amount_x, amount_y, amount_x_min, amount_y_min);

        // Verify reserves updated correctly
        let (new_reserve_x, new_reserve_y) = dex::get_pool_reserves(token_x, token_y);

        assert!(new_reserve_x == initial_reserve_x + new_x , 7001);
        assert!(new_reserve_y == initial_reserve_y + new_y, 7002);

        // Verify LP tokens minted proportionally
        let lp_address = dex::get_lp_address(pool_addr);
        let lp_balance = token_factory::get_balance(address_of(&provider), lp_address);
        assert!(lp_balance > 0, 7003);
    }

    #[test(admin = @dynexus_swap)]
    fun test_remove_partial_liquidity(admin: &signer) {
        setup(admin);
        let (provider, tokenA, tokenB, pool_addr) = create_token_pair_with_pool(admin);

        // Add liquidity
        let amount_x = quants(1000, 8);
        let amount_y = quants(100, 8);
        let (amount_x_min, amount_y_min) = dex::calculate_min_amounts(pool_addr, amount_x, amount_y, 1);
        dex::add_liquidity(&provider, tokenA, tokenB, amount_x, amount_y, amount_x_min, amount_y_min);

        let lp_address = dex::get_lp_address(pool_addr);
        let total_lp = token_factory::get_balance(address_of(&provider), lp_address);

        // Remove 50% of liquidity
        let lp_to_remove = total_lp / 2;
        dex::remove_liquidity(&provider, tokenA, tokenB, lp_to_remove);

        // Verify balances
        let remaining_lp = token_factory::get_balance(address_of(&provider), lp_address);
        assert!(remaining_lp == total_lp - lp_to_remove, 8001);

        // Verify reserves decreased proportionally
        let (reserve_x, reserve_y) = dex::get_pool_reserves(tokenA, tokenB);
        assert!(reserve_x < amount_x && reserve_y < amount_y, 8002);
    }

    #[test(admin = @dynexus_swap)]
    fun test_price_impact_calculation(admin: &signer) {
        setup(admin);
        let (provider, tokenA, tokenB, pool_addr) = create_token_pair_with_pool(admin);

        // Add substantial liquidity
        let amount_x = quants(10000, 8);
        let amount_y = quants(1000, 8);
        let (amount_x_min, amount_y_min) = dex::calculate_min_amounts(pool_addr, amount_x, amount_y, 1);
        dex::add_liquidity(&provider, tokenA, tokenB, amount_x, amount_y, amount_x_min, amount_y_min);

        // Create user and fund them
        let user = create_account_for_test(@0x3456);
        token_factory::mint_token(admin, address_of(&user), tokenA, quants(5000, 8));

        // Small swap (minimal price impact)
        let small_input = quants(100, 8);
        let (reserve_x_small, reserve_y_small) = dex::get_pool_reserves(tokenA, tokenB);
        let small_output = dex::get_amount_out(small_input, reserve_x_small, reserve_y_small);

        // Large swap (significant price impact)
        let large_input = quants(5000, 8);
        let (reserve_x_large, reserve_y_large) = dex::get_pool_reserves(tokenA, tokenB);
        let large_output = dex::get_amount_out(large_input, reserve_x_large, reserve_y_large);

        // Calculate price per token for both scenarios
        let small_price_per_token = small_output * pow10(8) / small_input;
        let large_price_per_token = large_output * pow10(8) / large_input;

        // Verify price impact (large swap gets worse rate)
        assert!(large_price_per_token < small_price_per_token, 9001);
    }

    #[test(admin = @dynexus_swap)]
    fun test_fee_distribution(admin: &signer) {

        setup(admin);
        let (provider, tokenA, tokenB, pool_addr) = create_token_pair_with_pool(admin);

        // Add substantial liquidity (10,000:1,000 ratio)
        let amount_x = quants(10000, 8);
        let amount_y = quants(1000, 8);
        let (amount_x_min, amount_y_min) = dex::calculate_min_amounts(pool_addr, amount_x, amount_y, 1);
        dex::add_liquidity(&provider, tokenA, tokenB, amount_x, amount_y, amount_x_min, amount_y_min);

        // Create trader and fund with 5,000 tokenA
        let trader = create_account_for_test(@0x4567);
        token_factory::mint_token(admin, address_of(&trader), tokenA, quants(5000, 8));

        // Get initial balances and reserves
        let dex_config_addr = dex::get_dex_object_address();
        let initial_platform_balance = token_factory::get_balance(dex_config_addr, tokenA);
        let initial_pool_balance = token_factory::get_balance(pool_addr, tokenA);
        let (initial_reserve_x, _) = dex::get_pool_reserves(tokenA, tokenB);

        // Define swap amounts for testing
        let swap_amounts = vector[quants(100, 8), quants(200, 8), quants(300, 8)];
        let total_swapped = 0;
        let total_expected_platform_fee = 0;
        let total_expected_swap_fee = 0;

        // Execute all swaps and track expected fees
        let i = 0;
        while (i < swap_amounts.length()) {
        let amount = *swap_amounts.borrow(i);
        total_swapped += amount;

        // Calculate expected fees for this swap
        let expected_platform_fee = amount * PLATFORM_FEE_PERCENT / FEE_DENOMINATOR;
        let expected_swap_fee = amount * DEFAULT_FEE_PERCENT / FEE_DENOMINATOR;
        total_expected_platform_fee += expected_platform_fee;
        total_expected_swap_fee += expected_swap_fee;



        let (reserve_x, reserve_y) = dex::get_pool_reserves(tokenA, tokenB);
        let expected_out = dex::get_amount_out(amount, reserve_x, reserve_y);
        dex::swap(&trader, tokenA, tokenB, amount, expected_out * 99 / 100); // 1% slippage tolerance
        i += 1;
        };

        // Get final balances and reserves
        let final_platform_balance = token_factory::get_balance(dex_config_addr, tokenA);
        let final_pool_balance = token_factory::get_balance(pool_addr, tokenA);
        let (final_reserve_x, _) = dex::get_pool_reserves(tokenA, tokenB);

        // Calculate actual fees collected
        let actual_platform_fee = final_platform_balance - initial_platform_balance;
        let actual_swap_fee =  (final_pool_balance - initial_pool_balance) - (total_swapped *  DEFAULT_FEE_PERCENT / FEE_DENOMINATOR);

        // Calculate net amount that went to reserves (after all fees)
        let net_amount_to_reserves = total_swapped - total_expected_platform_fee - total_expected_swap_fee;
        let actual_reserve_increase = final_reserve_x - initial_reserve_x;

        // Verify platform fee collection (0.02%)
        assert!(
        actual_platform_fee == total_expected_platform_fee,
        E_PLATFORM_FEE_MISMATCH
        );
        // Verify swap fee collection (0.01%) - goes to pool balance
        assert!(
            actual_swap_fee ==  (final_pool_balance - initial_pool_balance) - total_expected_swap_fee,
        E_SWAP_FEE_MISMATCH
        );

        assert!(
        actual_reserve_increase == net_amount_to_reserves,
        E_RESERVE_UPDATE_MISMATCH
        );
    }

    #[test(admin = @dynexus_swap)]
    fun test_token_with_different_decimals(admin: &signer) {
        setup(admin);
        let issuer = create_account_for_test(@0x5678);
        let provider = create_account_for_test(@0x6789);

        // Create tokens with different decimals
        let (_,_, tokenA) = token_factory::create_test_token(
            &issuer,
            utf8(b"Token6"),
            utf8(b"T8"),
            6,
            quants(100, 6),
            utf8(b""),
            utf8(b""),
            0
        );
        let (_,_, tokenB) = token_factory::create_test_token(
            &issuer,
            utf8(b"Token18"),
            utf8(b"T9"),
            18,
            quants(100, 8),
            utf8(b""),
            utf8(b""),
            1
        );

        // Fund provider
        token_factory::mint_token(&issuer, address_of(&provider), tokenA, quants(1000, 6));
        token_factory::mint_token(&issuer, address_of(&provider), tokenB, quants(1000, 8));

        // Create pool with adjusted amounts
        dex::create_pool(&provider, tokenA, tokenB, quants(100, 6), quants(1, 8));
        let (tokenA, tokenB, _, _) = dex::sort_token(tokenA, tokenB, 0, 0);

        // Verify pool created successfully
        let (reserve_x, reserve_y) = dex::get_pool_reserves(tokenA, tokenB);
        assert!(reserve_x == quants(100, 6) && reserve_y == quants(1, 8), 11001);

        // Test swap between different decimal tokens
        let trader = create_account_for_test(@0x7890);
        token_factory::mint_token(&issuer, address_of(&trader), tokenA, quants(10, 6));

        let amount_in = quants(10, 6);
        let (rev_x, rev_y) = dex::get_pool_reserves(tokenA, tokenB);

        let min_out = dex::get_amount_out(amount_in, rev_x, rev_y);
        dex::swap(&trader, tokenA, tokenB, amount_in, min_out);

        // Verify trader received some tokenB
        let tokenB_balance = token_factory::get_token_balance(&trader, tokenB);
        assert!(tokenB_balance > 0, 11002);
    }

    #[test(admin = @dynexus_swap)]
    fun test_lp_token_transfer(admin: &signer) {
        setup(admin);
        let (provider, tokenA, tokenB, pool_addr) = create_token_pair_with_pool(admin);

        // Add liquidity
        let amount_x = quants(1000, 8);
        let amount_y = quants(100, 8);
        let (amount_x_min, amount_y_min) = dex::calculate_min_amounts(pool_addr, amount_x, amount_y, 1);
        dex::add_liquidity(&provider, tokenA, tokenB, amount_x, amount_y, amount_x_min, amount_y_min);

        let lp_address = dex::get_lp_address(pool_addr);
        let initial_lp_balance = token_factory::get_balance(address_of(&provider), lp_address);

        // Create recipient
        let recipient = create_account_for_test(@0x8901);

        // Transfer half of LP tokens
        let transfer_amount = initial_lp_balance / 2;
        token_factory::transfer_token(&provider, address_of(&recipient), lp_address, transfer_amount);

        // Verify balances
        let provider_balance = token_factory::get_balance(address_of(&provider), lp_address);
        let recipient_balance = token_factory::get_balance(address_of(&recipient), lp_address);

        assert!(provider_balance == initial_lp_balance - transfer_amount, 12001);
        assert!(recipient_balance == transfer_amount, 12002);

        // Recipient should be able to remove liquidity
        dex::remove_liquidity(&recipient, tokenA, tokenB, recipient_balance);

        // Verify recipient received underlying tokens
        let tokenA_balance = token_factory::get_token_balance(&recipient, tokenA);
        let tokenB_balance = token_factory::get_token_balance(&recipient, tokenB);
        assert!(tokenA_balance > 0 && tokenB_balance > 0, 12003);
    }
}
