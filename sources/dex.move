module dynexus_swap::dex {

    use std::bcs::to_bytes;
    use std::option;
    use std::signer::address_of;
    use std::string::{utf8, String};
    use std::vector;
    use aptos_std::comparator;
    use aptos_std::math64;
    use aptos_std::table;
    use aptos_std::table::Table;
    use aptos_framework::event;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::{Metadata, MintRef, BurnRef};
    use aptos_framework::object;
    use aptos_framework::object::{ExtendRef, address_to_object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    //
    // Constants
    //
    /// Contract address
    const CA: address = @dynexus_swap;
    const DEX_ACCOUNT_SEED: vector<u8> = b"DYNEXUS_DEX";
    const POOL_OBJ_SEED: vector<u8> = b"DYNEXUS_POOL_";
    const INITIAL_LIQUIDITY_LOCK: u64 = 1000; // Minimum liquidity
    const MAX_U64: u64 = 18446744073709551615u64;
    const MAX_SINGLE_SWAP_PERCENT: u64 = 1000; // Max swap
    const FEE_DENOMINATOR: u64 = 10000;

    //
    // Errors
    //

    /// User is not an admin
    const E_NOT_AN_ADMIN: u64 = 0;

    /// Dex config already exists
    const E_DEX_ALREADY_EXISTS: u64 = 1;

    /// Registry already exists
    const E_REGISTRY_ALREADY_EXISTS: u64 = 2;

    /// Tokens must be different to create a pool
    const E_TOKENS_MUST_BE_DIFFERENT: u64 = 3;

    /// Pool already exists
    const E_POOL_ALREADY_EXISTS: u64 = 4;

    /// Amount can't be zero
    const E_ZERO_AMOUNT: u64 = 5;

    /// Invalid fee percentage (must be < 10000 basis points)
    const E_INVALID_FEE: u64 = 6;

    /// Insufficient liquidity
    const E_INSUFFICIENT_LIQUIDITY: u64 = 7;

    /// Pool does not exist
    const E_POOL_NOT_EXISTS: u64 = 8;

    /// Insufficient input amount
    const E_INSUFFICIENT_INPUT_AMOUNT: u64 = 9;

    /// Registry not found
    const E_REGISTRY_NOT_EXISTS: u64 = 10;

    /// Insufficient output amount
    const E_INSUFFICIENT_OUTPUT_AMOUNT: u64 = 11;

    /// Value too large
    const E_LARGE_VALUES: u64 = 12;

    /// Invalid token deposit ratio
    const E_INVALID_DEPOSIT_RATIO: u64 = 13;

    /// Invalid token order
    const E_WRONG_TOKEN_ORDER: u64 = 14;

    /// Transaction deadline exceeded
    const E_DEADLINE_EXCEEDED: u64 = 15;

    /// Exceed the MAX swap limit
    const E_EXCESSIVE_SWAP: u64 = 16;

    /// Invalid initial liquidity
    const E_INVALID_INITIAL_LIQUIDITY: u64 = 17;

    /// Reentrancy grard actived
    const E_REENTRANCY: u64 = 18;

    //
    // Structs
    //
    struct DexConfig has key {
        default_fee_percent: u64,
        platform_fee_percent: u64,
        platform_fee_recipient: address,
        extend_ref: ExtendRef,
        pools: Table<u64, address>,
        total_pools: u64
    }

    /// LiquidityPool holds pool info
    struct LiquidityPool has key {
        token_x: address,
        token_y: address,
        lp_token: address,
        reserve_x: u64,
        reserve_y: u64,
        lp_token_supply: u64,
        extend_ref: ExtendRef,
        mint_ref: MintRef,
        burn_ref: BurnRef
    }

    #[event]
    struct TokenCratedEvent has drop, store {
        token_addr: address,
        owner_addr: address,
        name: String,
        symbol: String,
        created_at: u64
    }

    #[event]
    struct PoolCratedEvent has drop, store {
        pool_addr: address,
        lp_token_supply: u64,
        reserve_x: u64,
        reserve_y: u64,
        platform_fee_percent: u64,
        platform_fee_recipient: address,
        fee_percent: u64,
        created_at: u64
    }

    #[event]
    struct DexInitializedEvent has drop, store {
        default_fee_percent: u64,
        platform_fee_percent: u64,
        created_at: u64
    }

    #[event]
    struct SwapEvent has drop, store {
        pool_address: address,
        trader: address,
        token_in: address,
        token_out: address,
        amount_in: u64,
        amount_out: u64,
        swap_fee: u64,
        platform_fee: u64,
        new_reserve_x: u64,
        new_reserve_y: u64,
        timestamp: u64
    }

    #[event]
    struct LiquidityAddedEvent has drop, store {
        pool_address: address,
        provider: address,
        token_x: address,
        token_y: address,
        amount_x: u64,
        amount_y: u64,
        lp_tokens_minted: u64,
        new_reserve_x: u64,
        new_reserve_y: u64,
        timestamp: u64
    }

    #[event]
    struct LiquidityRemovedEvent has drop, store {
        pool_address: address,
        provider: address,
        token_x: address,
        token_y: address,
        amount_x: u64,
        amount_y: u64,
        lp_tokens_burned: u64,
        new_reserve_x: u64,
        new_reserve_y: u64,
        timestamp: u64
    }

    #[event]
    struct PoolUpdatedEvent has drop, store {
        pool_address: address,
        reserve_x: u64,
        reserve_y: u64,
        lp_token_supply: u64,
        price_x_per_y: u64, // For price tracking
        price_y_per_x: u64,
        timestamp: u64
    }

    #[event]
    struct FeeCollectedEvent has drop, store {
        pool_address: address,
        token: address,
        fee_type: String, // "swap" or "platform"
        amount: u64,
        recipient: address,
        timestamp: u64
    }

    /// Initialize Dex module
    fun init_module(admin: &signer) {
        let admin_addr = address_of(admin);
        assert_platform_admin(&admin_addr);

        let constructor_ref = &object::create_named_object(admin, DEX_ACCOUNT_SEED);
        let obj_signer = &object::generate_signer(constructor_ref);
        let extend_ref = object::generate_extend_ref(constructor_ref);

        let (default_fee_percent, platform_fee_percent) = (1, 2);

        move_to(
            obj_signer,
            DexConfig {
                default_fee_percent, // (0.01%)
                platform_fee_percent, // (0.02%)
                platform_fee_recipient: address_of(obj_signer),
                pools: table::new(),
                total_pools: 0,
                extend_ref
            }
        );

        event::emit(
            DexInitializedEvent {
                default_fee_percent,
                platform_fee_percent,
                created_at: timestamp::now_seconds()
            }
        );
    }

    //
    // Entry Functions
    //

    /// Create liquidity pool
    public entry fun create_pool(
        owner: &signer,
        token_x: address,
        token_y: address,
        amount_x: u64,
        amount_y: u64
    ) acquires DexConfig {
        if (amount_x < INITIAL_LIQUIDITY_LOCK || amount_y < INITIAL_LIQUIDITY_LOCK) {
            abort E_INVALID_INITIAL_LIQUIDITY
        };

        let res_addr = get_dex_object_address();
        let dex_config = borrow_global_mut<DexConfig>(res_addr);

        let fee_percent = dex_config.default_fee_percent;
        let platform_fee_percent = dex_config.platform_fee_percent;
        let platform_fee_recipient = dex_config.platform_fee_recipient;

        // Tokens must be different
        assert!(token_x != token_y, E_TOKENS_MUST_BE_DIFFERENT);

        validate_pool_creation_parameters(amount_x, amount_y);

        // Sort tokens
        let (token_x_sorted, token_y_sorted, amount_x_sorted, amount_y_sorted) =
            sort_token(token_x, token_y, amount_x, amount_y);

        // Create pool account
        let pool_seed = generate_pool_seed(&token_x_sorted, &token_y_sorted);
        let obj_signer = &object::generate_signer_for_extending(&dex_config.extend_ref);
        let pool_addr = object::create_object_address(
            &address_of(obj_signer), pool_seed
        );
        assert_pool_not_exist(&pool_addr);

        // Initialize LP token
        let constructor_ref = &object::create_named_object(obj_signer, pool_seed);
        let (lp_token_name, lp_token_symbol, lp_token_decimals) =
            initialize_lp_token(token_x_sorted, token_y_sorted);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            option::none(),
            lp_token_name,
            lp_token_symbol,
            lp_token_decimals,
            utf8(b""),
            utf8(b"")
        );

        // Generate mint/burn refs
        let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(constructor_ref);

        // 1. TRANSFER TOKENS TO POOL FIRST
        let token_x_metadata = object::address_to_object<Metadata>(token_x_sorted);
        let token_y_metadata = object::address_to_object<Metadata>(token_y_sorted);

        primary_fungible_store::transfer(
            owner,
            token_x_metadata,
            pool_addr,
            amount_x_sorted
        );
        primary_fungible_store::transfer(
            owner,
            token_y_metadata,
            pool_addr,
            amount_y_sorted
        );

        // 2. CALCULATE AND MINT LP TOKENS
        let initial_lp_token =
            calculate_initial_lp_tokens(amount_x_sorted, amount_y_sorted);
        let lp_asset = fungible_asset::mint(&mint_ref, initial_lp_token);
        primary_fungible_store::deposit(address_of(owner), lp_asset);

        // 3. INITIALIZE POOL STATE
        let extend_ref = object::generate_extend_ref(constructor_ref);
        let token_signer = object::generate_signer(constructor_ref);
        let lp_token = address_of(&token_signer);

        let pool_count = dex_config.total_pools + 1;
        dex_config.pools.upsert(pool_count, pool_addr);
        dex_config.total_pools = pool_count;

        move_to(
            &token_signer,
            LiquidityPool {
                token_x: token_x_sorted,
                token_y: token_y_sorted,
                lp_token,
                lp_token_supply: initial_lp_token,
                reserve_x: amount_x_sorted,
                reserve_y: amount_y_sorted,
                extend_ref,
                mint_ref,
                burn_ref
            }
        );

        event::emit(
            PoolCratedEvent {
                pool_addr,
                lp_token_supply: initial_lp_token,
                reserve_x: amount_x_sorted,
                reserve_y: amount_y_sorted,
                platform_fee_percent,
                platform_fee_recipient,
                fee_percent,
                created_at: timestamp::now_seconds()
            }
        );
    }

    /// Add liquidity to an existing pool
    public entry fun add_liquidity(
        provider: &signer,
        token_x: address,
        token_y: address,
        amount_x_desired: u64, // Desired amount of TokenA
        amount_y_desired: u64, // Desired amount of TokenB
        amount_x_min: u64, // Minimum acceptable TokenA (after slippage)
        amount_y_min: u64, // Minimum acceptable TokenB (after slippage)
        deadline: u64 // Transaction deadline for MEV protection
    ) acquires LiquidityPool {
        // Deadline protection against MEV
        assert!(timestamp::now_seconds() <= deadline, E_DEADLINE_EXCEEDED);

        let pool_addr = get_pool_object_address(token_x, token_y);
        assert_pool_exist(&pool_addr);
        let pool = borrow_global_mut<LiquidityPool>(pool_addr);

        let (token_x_sorted, token_y_sorted, amount_x_sorted, amount_y_sorted) =
            sort_token(
                token_x,
                token_y,
                amount_x_desired,
                amount_y_desired
            );
        assert!(
            token_x_sorted == pool.token_x && token_y_sorted == pool.token_y,
            E_WRONG_TOKEN_ORDER
        );

        let (amount_x, amount_y) =
            calculate_optimal_add_amounts(
                pool.reserve_x,
                pool.reserve_y,
                amount_x_sorted,
                amount_y_sorted
            );

        if (token_x == token_x_sorted) {
            // Original order matches sorted order
            assert!(amount_x >= amount_x_min, E_INSUFFICIENT_INPUT_AMOUNT);
            assert!(amount_y >= amount_y_min, E_INSUFFICIENT_INPUT_AMOUNT);
        } else {
            // Original order was reversed
            assert!(amount_y >= amount_x_min, E_INSUFFICIENT_INPUT_AMOUNT);
            assert!(amount_x >= amount_y_min, E_INSUFFICIENT_INPUT_AMOUNT);
        };

        // RATIO VALIDATION: Ensure we're not significantly changing pool ratio
        validate_liquidity_ratio(
            pool.reserve_x,
            pool.reserve_y,
            amount_x,
            amount_y
        );

        // Calculate LP tokens FIRST (before changing reserves)
        let lp_tokens_to_mint =
            calculate_lp_tokens_for_deposit(
                amount_x,
                amount_y,
                pool.reserve_x,
                pool.reserve_y,
                pool.lp_token_supply
            );

        // Update reserves FIRST
        pool.reserve_x += amount_x;
        pool.reserve_y += amount_y;
        pool.lp_token_supply += lp_tokens_to_mint;

        // Transfer tokens
        let provider_addr = address_of(provider);

        primary_fungible_store::transfer(
            provider,
            object::address_to_object<Metadata>(token_x_sorted),
            pool_addr,
            amount_x
        );

        primary_fungible_store::transfer(
            provider,
            object::address_to_object<Metadata>(token_y_sorted),
            pool_addr,
            amount_y
        );

        // Mint and deposit LP tokens
        let lp_asset = fungible_asset::mint(&pool.mint_ref, lp_tokens_to_mint);
        primary_fungible_store::deposit(provider_addr, lp_asset);

        // Emit liquidity added event
        event::emit(
            LiquidityAddedEvent {
                pool_address: pool_addr,
                provider: provider_addr,
                token_x: token_x_sorted,
                token_y: token_y_sorted,
                amount_x,
                amount_y,
                lp_tokens_minted: lp_tokens_to_mint,
                new_reserve_x: pool.reserve_x,
                new_reserve_y: pool.reserve_y,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Remove liquidity and receive token_x + token_y
    public entry fun remove_liquidity(
        provider: &signer,
        token_x_d: address,
        token_y_d: address,
        lp_amount: u64
    ) acquires LiquidityPool {
        assert!(lp_amount > 0, E_ZERO_AMOUNT);

        let (token_x, token_y, _, _) = sort_token(token_x_d, token_y_d, 0, 0);
        let pool_addr = get_pool_object_address(token_x, token_y);
        assert_pool_exist(&pool_addr);

        let pool = borrow_global_mut<LiquidityPool>(pool_addr);
        assert!(pool.lp_token_supply >= lp_amount, E_INSUFFICIENT_LIQUIDITY);

        let (amount_x, amount_y) =
            calculate_withdrawal_amounts(
                lp_amount,
                pool.reserve_x,
                pool.reserve_y,
                pool.lp_token_supply
            );

        let provider_addr = address_of(provider);
        let pool_singer = &object::generate_signer_for_extending(&pool.extend_ref);
        let token_x_metadata = object::address_to_object<Metadata>(pool.token_x);
        let token_y_metadata = object::address_to_object<Metadata>(pool.token_y);
        let lp_metadata = object::address_to_object<Metadata>(pool.lp_token);

        let lp_token = primary_fungible_store::withdraw(provider, lp_metadata, lp_amount);

        primary_fungible_store::transfer(
            pool_singer,
            token_x_metadata,
            provider_addr,
            amount_x
        );

        primary_fungible_store::transfer(
            pool_singer,
            token_y_metadata,
            provider_addr,
            amount_y
        );
        fungible_asset::burn(&pool.burn_ref, lp_token);

        pool.reserve_x -= amount_x;
        pool.reserve_y -= amount_y;
        pool.lp_token_supply -= lp_amount;

        event::emit(
            LiquidityRemovedEvent {
                pool_address: pool_addr,
                provider: provider_addr,
                token_x: pool.token_x,
                token_y: pool.token_y,
                amount_x,
                amount_y,
                lp_tokens_burned: lp_amount,
                new_reserve_x: pool.reserve_x,
                new_reserve_y: pool.reserve_y,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Swap between token_x and token_y
    public entry fun swap(
        trader: &signer,
        token_in: address,
        token_out: address,
        amount_in: u64,
        amount_out_min: u64,
        deadline: u64
    ) acquires DexConfig, LiquidityPool {
        // Deadline protection against MEV
        assert!(timestamp::now_seconds() <= deadline, E_DEADLINE_EXCEEDED);
        assert!(amount_in > 0, E_INSUFFICIENT_INPUT_AMOUNT);

        let res_addr = get_dex_object_address();
        let dex_config = borrow_global_mut<DexConfig>(res_addr);

        let pool_addr = get_pool_object_address(token_in, token_out);
        assert_pool_exist(&pool_addr);
        let pool = borrow_global_mut<LiquidityPool>(pool_addr);

        let (reserve_in, reserve_out, is_x_in) =
            if (token_in == pool.token_x && token_out == pool.token_y) {
                (pool.reserve_x, pool.reserve_y, true)
            } else if (token_in == pool.token_y && token_out == pool.token_x) {
                (pool.reserve_y, pool.reserve_x, false)
            } else {
                abort E_POOL_NOT_EXISTS
            };

        assert!(
            amount_in <= (reserve_in * MAX_SINGLE_SWAP_PERCENT) / 10000,
            E_EXCESSIVE_SWAP
        );
        assert!(
            reserve_in > 0 && reserve_out > 0,
            E_INSUFFICIENT_LIQUIDITY
        );

        // Calculate fees
        let platform_fee =
            (((amount_in as u128) * (dex_config.platform_fee_percent as u128))
                / (FEE_DENOMINATOR as u128) as u64);
        let swap_fee =
            (((amount_in as u128) * (dex_config.default_fee_percent as u128))
                / (FEE_DENOMINATOR as u128) as u64);
        let amount_in_after_fees = amount_in - platform_fee - swap_fee;

        // AMM calculation
        let numerator = (amount_in_after_fees as u256) * (reserve_out as u256);
        let denominator = (reserve_in as u256) + (amount_in_after_fees as u256);
        let amount_out = (numerator / denominator) as u64;

        // Slippage protection
        assert!(amount_out > 0, E_INSUFFICIENT_OUTPUT_AMOUNT);
        assert!(amount_out >= amount_out_min, E_INSUFFICIENT_OUTPUT_AMOUNT);

        // Update reserves
        let increased_reserve = amount_in_after_fees + swap_fee;
        if (is_x_in) {
            pool.reserve_x += increased_reserve;
            pool.reserve_y -= amount_out;
        } else {
            pool.reserve_y += increased_reserve;
            pool.reserve_x -= amount_out;
        };

        // Execute transfers
        let trader_addr = address_of(trader);
        let pool_signer = &object::generate_signer_for_extending(&pool.extend_ref);

        // User tranfer amount_in (including swap and plateform fees)
        let token_in_metadata = address_to_object<Metadata>(token_in);
        primary_fungible_store::transfer(
            trader,
            token_in_metadata,
            pool_addr,
            amount_in
        );

        // Pool transer plateform fee to the recipient
        primary_fungible_store::transfer(
            pool_signer,
            token_in_metadata,
            dex_config.platform_fee_recipient,
            platform_fee
        );

        // Pool transer amount to the trader
        primary_fungible_store::transfer(
            pool_signer,
            address_to_object<Metadata>(token_out),
            trader_addr,
            amount_out
        );

        // Emit event
        event::emit(
            SwapEvent {
                pool_address: pool_addr,
                trader: trader_addr,
                token_in,
                token_out,
                amount_in,
                amount_out,
                swap_fee,
                platform_fee,
                new_reserve_x: pool.reserve_x,
                new_reserve_y: pool.reserve_y,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    //
    // Public  Functions
    //

    /// Get `pool` object account address
    public fun get_pool_object_address(token_x: address, token_y: address): address {
        let (token_x_sorted, token_y_sorted, _, _) = sort_token(token_x, token_y, 0, 0);
        let seed = generate_pool_seed(&token_x_sorted, &token_y_sorted);
        let dex_addr = get_dex_object_address();
        let pool_addr = object::create_object_address(&dex_addr, seed);
        assert_pool_exist(&pool_addr);
        pool_addr
    }

    public fun get_lp_address(pool_address: address): address acquires LiquidityPool {
        assert_pool_exist(&pool_address);
        let pool = borrow_global<LiquidityPool>(pool_address);
        pool.lp_token
    }

    public fun calculate_min_amounts(
        pool_addr: address,
        amount_x_desired: u64,
        amount_y_desired: u64,
        slippage_percent: u64
    ): (u64, u64) acquires LiquidityPool {
        let pool = borrow_global<LiquidityPool>(pool_addr);
        let (expected_x, expected_y) =
            calculate_optimal_add_amounts(
                pool.reserve_x,
                pool.reserve_y,
                amount_x_desired,
                amount_y_desired
            );
        let amount_x_min = (expected_x * (100 - slippage_percent)) / 100;
        let amount_y_min = (expected_y * (100 - slippage_percent)) / 100;
        (amount_x_min, amount_y_min)
    }

    /// Get `dex` admin object account address
    public fun get_dex_object_address(): address {
        object::create_object_address(&CA, DEX_ACCOUNT_SEED)
    }

    /// Get the amount of output token for a given input
    public fun get_amount_out(
        amount_in: u64, reserve_in: u64, reserve_out: u64
    ): u64 acquires DexConfig {
        assert!(amount_in > 0, E_INSUFFICIENT_INPUT_AMOUNT);
        assert!(
            reserve_in > 0 && reserve_out > 0,
            E_INSUFFICIENT_LIQUIDITY
        );

        let dex_addr = get_dex_object_address();
        assert_dex_exist(&dex_addr);
        let dex = borrow_global<DexConfig>(dex_addr);

        // Calculate fees first
        let platform_fee = (amount_in * dex.platform_fee_percent) / FEE_DENOMINATOR;
        let swap_fee = (amount_in * dex.default_fee_percent) / FEE_DENOMINATOR;
        let amount_in_after_fees = amount_in - platform_fee - swap_fee; // AMM calculation amount

        // AMM calculation : x * y = k
        let numerator = (amount_in_after_fees as u256) * (reserve_out as u256);
        let denominator = (reserve_in as u256) + (amount_in_after_fees as u256);
        (numerator / denominator) as u64
    }

    public fun calculate_lp_value(
        pool_addr: address, lp_tokens: u64
    ): (u64, u64) acquires LiquidityPool {
        let pool = borrow_global<LiquidityPool>(pool_addr);
        let total_supply = pool.lp_token_supply;

        // How much (tokenA, tokenB) your LP tokens represent
        let amount_a = (pool.reserve_x * lp_tokens) / total_supply;
        let amount_b = (pool.reserve_y * lp_tokens) / total_supply;

        (amount_a, amount_b)
    }

    /// Sort tokens by address to ensure consistent ordering
    public fun sort_token(
        token_x: address,
        token_y: address,
        amount_x: u64,
        amount_y: u64
    ): (address, address, u64, u64) {
        let cmp = comparator::compare(&token_x, &token_y);

        if (cmp.is_smaller_than()) {
            (token_x, token_y, amount_x, amount_y)
        } else {
            (token_y, token_x, amount_y, amount_x)
        }
    }

    /// More accurate optimal amounts calculation
    public fun calculate_optimal_add_amounts(
        reserve_x: u64,
        reserve_y: u64,
        amount_x_desired: u64,
        amount_y_desired: u64
    ): (u64, u64) {
        if (reserve_x == 0 && reserve_y == 0) {
            return (amount_x_desired, amount_y_desired)
        };

        let amount_y_optimal =
            (((amount_x_desired as u256) * (reserve_y as u256)) / (reserve_x as u256)) as u64;

        if (amount_y_optimal <= amount_y_desired) {
            return (amount_x_desired, amount_y_optimal)
        };

        let amount_x_optimal =
            (((amount_y_desired as u256) * (reserve_x as u256)) / (reserve_y as u256)) as u64;
        (amount_x_optimal, amount_y_desired)
    }

    /// Validate that liquidity addition doesn't drastically change pool ratios
    fun validate_liquidity_ratio(
        reserve_x: u64,
        reserve_y: u64,
        amount_x: u64,
        amount_y: u64
    ) {
        // Skip validatetion for initial liquidity
        if (reserve_x == 0 || reserve_y == 0) return;

        // Calculate current and new ratios
        let current_ratio = (reserve_x as u256) * 1_000_000 / (reserve_y as u256);
        let new_ratio =
            ((reserve_x + amount_x) as u256) * 1_000_000
                / ((reserve_y + amount_y) as u256);

        // Allow maximum 0.1% ratio change (1000 = 0.1% of 1_000_000)
        let ratio_diff =
            if (new_ratio > current_ratio) {
                new_ratio - current_ratio
            } else {
                current_ratio - new_ratio
            };

        // Maximum allowed ratio change(0.1%)
        let max_ratio_change = 1000;
        assert!(ratio_diff <= max_ratio_change, E_INVALID_DEPOSIT_RATIO);
    }

    //
    // Internal Functions
    //

    /// View the estimated swap output, fees, and net output
    fun view_swap(
        pool_addr: address,
        token_in: address,
        token_out: address,
        amount_in: u64,
        fee_percent: u64,
        platform_fee_percent: u64
    ): (
        u64 /* amount_out */,
        u64 /* swap_fee */,
        u64 /* platform_fee */,
        u64 /* net_received */
    ) acquires LiquidityPool {
        let pool = borrow_global<LiquidityPool>(pool_addr);

        let reserve_in;
        let reserve_out;

        if (token_in == pool.token_x && token_out == pool.token_y) {
            reserve_in = pool.reserve_x;
            reserve_out = pool.reserve_y;
        } else if (token_in == pool.token_y && token_out == pool.token_x) {
            reserve_in = pool.reserve_y;
            reserve_out = pool.reserve_x;
        } else {
            abort E_POOL_NOT_EXISTS;
        };

        let (amount_out, swap_fee, platform_fee) =
            get_amount_out_with_fees(
                amount_in,
                reserve_in,
                reserve_out,
                fee_percent,
                platform_fee_percent
            );

        (amount_out, swap_fee, platform_fee, amount_out)
    }

    /// Generate seed for a pool based on its tokens
    fun generate_pool_seed(
        token_x_addr: &address, token_y_addr: &address
    ): vector<u8> {
        let (token_x, token_y, _, _) = sort_token(*token_x_addr, *token_y_addr, 0, 0);
        let seed = vector::empty<u8>();
        seed.append(b"dynexus_pool_v1_");
        seed.append(to_bytes(&token_x));
        seed.append(b"_");
        seed.append(to_bytes(&token_y));
        seed
    }

    /// Validates all parameters for pool creation
    fun validate_pool_creation_parameters(amount_x: u64, amount_y: u64) {
        //Validate amounts
        assert!(amount_x > 0 && amount_y > 0, E_ZERO_AMOUNT);
    }

    /// initialize LP token metadata
    fun initialize_lp_token(token_x: address, token_y: address): (String, String, u8) {
        let token_x_metadata = address_to_object<Metadata>(token_x);
        let token_y_metadata = address_to_object<Metadata>(token_y);

        let token_x_symbol = fungible_asset::symbol(token_x_metadata);
        let token_y_symbol = fungible_asset::symbol(token_y_metadata);

        // Create LP token name (e.g., "DYNEXUS LP Token X-Y")
        let lp_token_name = utf8(b"DYNEXUS LP Token ");
        lp_token_name.append(token_x_symbol);
        lp_token_name.append(utf8(b"-"));
        lp_token_name.append(token_y_symbol);

        // Create LP token symbol (e.g., "DYNEXUS-X-Y")
        let lp_token_symbol = utf8(b"DYNEXUS-LP-");
        lp_token_symbol.append(token_x_symbol);
        lp_token_symbol.append(utf8(b"-"));
        lp_token_symbol.append(token_y_symbol);

        // Use higher decimals of the two tokens
        let token_x_decimals = fungible_asset::decimals(token_x_metadata);
        let token_y_decimals = fungible_asset::decimals(token_y_metadata);
        let lp_token_decimals =
            if (token_x_decimals > token_y_decimals) {
                token_x_decimals
            } else {
                token_y_decimals
            };

        (lp_token_name, lp_token_symbol, lp_token_decimals)
    }

    /// Calculate initial LP tokens using geometric mean formula
    fun calculate_initial_lp_tokens(amount_x: u64, amount_y: u64): u64 {

        let product = (amount_x as u256) * (amount_y as u256);
        if (product == 0) return 0;

        // Safety check before casting to u64
        if (product > (MAX_U64 as u256)) {
            abort E_LARGE_VALUES
        };

        math64::sqrt(product as u64)

    }

    /// Proper LP token calculation maintaining invariants
    fun calculate_lp_tokens_for_deposit(
        amount_x: u64,
        amount_y: u64,
        reserve_x: u64,
        reserve_y: u64,
        total_supply: u64
    ): u64 {
        if (total_supply == 0) {
            return math64::sqrt(((amount_x as u256) * (amount_y as u256)) as u64)
        };

        // Calculate based on both reserves proportionally
        let lp_from_x = ((amount_x as u256) * (total_supply as u256)) / (reserve_x as u256);
        let lp_from_y = ((amount_y as u256) * (total_supply as u256)) / (reserve_y as u256);

        // Take the minimum to maintain ratio
        if (lp_from_x < lp_from_y) {
            lp_from_x as u64
        } else {
            lp_from_y as u64
        }
    }

    /// Calculate withdrawal amounts based on LP tokens
    fun calculate_withdrawal_amounts(
        lp_tokens: u64,
        reserve_x: u64,
        reserve_y: u64,
        total_supply: u64
    ): (u64, u64) {
        assert!(lp_tokens <= total_supply, E_INSUFFICIENT_LIQUIDITY);
        assert!(
            reserve_x > 0 && reserve_y > 0,
            E_INSUFFICIENT_LIQUIDITY
        );
        let amount_x =
            ((((lp_tokens as u256) * (reserve_x as u256)) / (total_supply as u256)) as u64);
        let amount_y =
            ((((lp_tokens as u256) * (reserve_y as u256)) / (total_supply as u256)) as u64);

        (amount_x, amount_y)
    }

    /// Get amount out with call fees calculated
    fun get_amount_out_with_fees(
        amount_in: u64,
        reserve_in: u64,
        reserve_out: u64,
        fee_percent: u64, // 1 = 0.01%
        platform_fee_percent: u64 // 2 = 0.02%
    ): (u64 /* amount_out */, u64 /* swap_fee */, u64 /* platform_fee */) {
        // Calculate both fees from original amount
        let platform_fee = amount_in * platform_fee_percent / FEE_DENOMINATOR;
        let swap_fee = amount_in * fee_percent / FEE_DENOMINATOR;

        let amount_in_after_fees = amount_in - platform_fee - swap_fee;

        let numerator = (amount_in_after_fees as u256) * (reserve_out as u256);
        let denominator = (reserve_in as u256) + (amount_in_after_fees as u256);
        let amount_out = (numerator / denominator) as u64;

        (amount_out, swap_fee, platform_fee)
    }

    //
    // View function
    //

    #[view]
    /// View reserves of a pool
    public fun get_pool_reserves(pool_address: address): (u64, u64) acquires LiquidityPool {
        assert_pool_exist(&pool_address);

        let pool = borrow_global<LiquidityPool>(pool_address);
        (pool.reserve_x, pool.reserve_y)
    }

    #[view]
    /// View total supply of a lp
    public fun get_total_supply(pool_address: address): (u64) acquires LiquidityPool {
        assert_pool_exist(&pool_address);
        let pool = borrow_global<LiquidityPool>(pool_address);
        pool.lp_token_supply
    }

    #[view]
    /// View Pool info
    /// # Returns
    /// (lp_token, reserve_x, reserve_y, lp_token_supply, fee_percent, platform_fee_percent, platform_fee_recipient)
    public fun get_pool_info(
        pool_address: address
    ): (address, u64, u64, u64, u64, u64, address) acquires DexConfig, LiquidityPool {
        assert_pool_exist(&pool_address);
        let dex_address = get_dex_object_address();

        let dex = borrow_global<DexConfig>(dex_address);
        let pool = borrow_global<LiquidityPool>(pool_address);

        (
            pool.lp_token,
            pool.reserve_x,
            pool.reserve_y,
            pool.lp_token_supply,
            dex.default_fee_percent,
            dex.platform_fee_percent,
            dex.platform_fee_recipient
        )
    }

    //
    // Assert Functions
    //

    /// Assert if dex is exists
    fun assert_dex_exist(dex_address: &address) {
        assert!(exists<DexConfig>(*dex_address), E_POOL_NOT_EXISTS);
    }

    /// Assert if pool is already exists at `pool_addr` address
    fun assert_pool_exist(pool_addr: &address) {
        assert!(exists<LiquidityPool>(*pool_addr), E_POOL_NOT_EXISTS);
    }

    /// Assert if pool is not exists at `pool_addr` address
    fun assert_pool_not_exist(pool_addr: &address) {
        assert!(!exists<LiquidityPool>(*pool_addr), E_POOL_ALREADY_EXISTS);
    }

    /// Assert if initial token supply is zero `0`
    fun assert_initial_token_supply_zero(supply: u64) {
        assert!(supply > 0, E_ZERO_AMOUNT);
    }

    /// Check user is platform admin
    fun assert_platform_admin(admin_addr: &address) {
        assert!(*admin_addr == CA, E_NOT_AN_ADMIN);
    }

    /// Check is config already exists
    fun assert_registries_already_exists(addr: &address) {
        assert!(!exists<DexConfig>(*addr), E_DEX_ALREADY_EXISTS);
    }

    //
    // Test Functions
    //

    #[test_only]
    public fun test_init_dex(admin: &signer) {
        init_module(admin);
    }
}
