module dynexus_swap::dex {

    use std::bcs::to_bytes;
    use std::option;
    use std::signer::address_of;
    use std::string::{utf8, String};
    use std::vector;
    use aptos_std::comparator;
    use aptos_std::math128;
    use aptos_std::table;
    use aptos_std::table::Table;
    use aptos_framework::event;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::{FungibleAsset, Metadata, MintRef, BurnRef};
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
    /// Minimum amount of each token required to create a pool
    const INITIAL_LIQUIDITY_LOCK: u64 = 1000;
    /// LP tokens minted to the pool itself on creation and locked forever,
    /// so reserves can never be fully drained.
    const MINIMUM_LIQUIDITY: u64 = 1000;
    const MAX_U64: u64 = 18446744073709551615u64;
    /// Max single swap input, in basis points of the input reserve (10%)
    const MAX_SINGLE_SWAP_PERCENT: u64 = 1000;
    const FEE_DENOMINATOR: u64 = 10000;
    /// Upper bound for each of swap fee and platform fee (1%)
    const MAX_FEE_BPS: u64 = 100;
    /// Longest swap route, in tokens (3 hops)
    const MAX_ROUTE_LENGTH: u64 = 4;
    /// Max pools returned by a single paginated view call
    const MAX_PAGE_SIZE: u64 = 100;

    //
    // Errors
    //

    /// User is not an admin
    const E_NOT_AN_ADMIN: u64 = 0;

    /// Tokens must be different to create a pool
    const E_TOKENS_MUST_BE_DIFFERENT: u64 = 3;

    /// Pool already exists
    const E_POOL_ALREADY_EXISTS: u64 = 4;

    /// Amount can't be zero
    const E_ZERO_AMOUNT: u64 = 5;

    /// Invalid fee (each fee must be <= MAX_FEE_BPS)
    const E_INVALID_FEE: u64 = 6;

    /// Insufficient liquidity
    const E_INSUFFICIENT_LIQUIDITY: u64 = 7;

    /// Pool does not exist
    const E_POOL_NOT_EXISTS: u64 = 8;

    /// Insufficient input amount
    const E_INSUFFICIENT_INPUT_AMOUNT: u64 = 9;

    /// Insufficient output amount
    const E_INSUFFICIENT_OUTPUT_AMOUNT: u64 = 11;

    /// Value too large
    const E_LARGE_VALUES: u64 = 12;

    /// Invalid token order
    const E_WRONG_TOKEN_ORDER: u64 = 14;

    /// Transaction deadline exceeded
    const E_DEADLINE_EXCEEDED: u64 = 15;

    /// Exceed the MAX swap limit
    const E_EXCESSIVE_SWAP: u64 = 16;

    /// Invalid initial liquidity
    const E_INVALID_INITIAL_LIQUIDITY: u64 = 17;

    /// Swap route must contain 2..=MAX_ROUTE_LENGTH tokens with no repeated neighbours
    const E_INVALID_ROUTE: u64 = 19;

    /// Slippage percent must be <= 100
    const E_INVALID_SLIPPAGE: u64 = 20;

    //
    // Structs
    //
    struct DexConfig has key {
        /// Swap fee kept in the pool for LPs, in basis points
        default_fee_percent: u64,
        /// Protocol fee sent to `platform_fee_recipient`, in basis points
        platform_fee_percent: u64,
        platform_fee_recipient: address,
        extend_ref: ExtendRef,
        pools: Table<u64, address>,
        total_pools: u64
    }

    /// LiquidityPool holds pool info. Lives at the pool object, which is also the LP token metadata.
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

    //
    // Events
    //
    #[event]
    struct PoolCratedEvent has drop, store {
        pool_addr: address,
        token_x: address,
        token_y: address,
        creator: address,
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
    struct FeeConfigUpdatedEvent has drop, store {
        default_fee_percent: u64,
        platform_fee_percent: u64,
        platform_fee_recipient: address
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
                platform_fee_recipient: admin_addr,
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
    // Admin
    //

    /// Update swap/platform fees (basis points, each <= MAX_FEE_BPS).
    public entry fun set_fees(
        admin: &signer, default_fee_percent: u64, platform_fee_percent: u64
    ) acquires DexConfig {
        assert_platform_admin(&address_of(admin));
        assert!(
            default_fee_percent <= MAX_FEE_BPS && platform_fee_percent <= MAX_FEE_BPS,
            E_INVALID_FEE
        );
        let config = borrow_global_mut<DexConfig>(get_dex_object_address());
        config.default_fee_percent = default_fee_percent;
        config.platform_fee_percent = platform_fee_percent;
        emit_fee_config(config);
    }

    public entry fun set_platform_fee_recipient(
        admin: &signer, recipient: address
    ) acquires DexConfig {
        assert_platform_admin(&address_of(admin));
        let config = borrow_global_mut<DexConfig>(get_dex_object_address());
        config.platform_fee_recipient = recipient;
        emit_fee_config(config);
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
        // Tokens must be different
        assert!(token_x != token_y, E_TOKENS_MUST_BE_DIFFERENT);
        if (amount_x < INITIAL_LIQUIDITY_LOCK || amount_y < INITIAL_LIQUIDITY_LOCK) {
            abort E_INVALID_INITIAL_LIQUIDITY
        };

        let dex_config = borrow_global_mut<DexConfig>(get_dex_object_address());

        // Sort tokens
        let (
            token_x_sorted, token_y_sorted, amount_x_sorted, amount_y_sorted
        ) = sort_token(token_x, token_y, amount_x, amount_y);

        // Create pool object (also the LP token metadata)
        let pool_seed = generate_pool_seed(&token_x_sorted, &token_y_sorted);
        let obj_signer = &object::generate_signer_for_extending(&dex_config.extend_ref);
        let pool_addr = object::create_object_address(
            &address_of(obj_signer), pool_seed
        );
        assert_pool_not_exist(&pool_addr);

        let initial_lp_token =
            calculate_initial_lp_tokens(amount_x_sorted, amount_y_sorted);
        assert!(initial_lp_token > MINIMUM_LIQUIDITY, E_INVALID_INITIAL_LIQUIDITY);

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

        let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(constructor_ref);
        let extend_ref = object::generate_extend_ref(constructor_ref);

        // Transfer initial liquidity into the pool
        primary_fungible_store::transfer(
            owner,
            address_to_object<Metadata>(token_x_sorted),
            pool_addr,
            amount_x_sorted
        );
        primary_fungible_store::transfer(
            owner,
            address_to_object<Metadata>(token_y_sorted),
            pool_addr,
            amount_y_sorted
        );

        // Mint LP: lock MINIMUM_LIQUIDITY in the pool, rest to the creator
        let owner_addr = address_of(owner);
        primary_fungible_store::deposit(
            pool_addr, fungible_asset::mint(&mint_ref, MINIMUM_LIQUIDITY)
        );
        primary_fungible_store::deposit(
            owner_addr,
            fungible_asset::mint(&mint_ref, initial_lp_token - MINIMUM_LIQUIDITY)
        );

        let pool_count = dex_config.total_pools + 1;
        dex_config.pools.add(pool_count, pool_addr);
        dex_config.total_pools = pool_count;

        move_to(
            &object::generate_signer(constructor_ref),
            LiquidityPool {
                token_x: token_x_sorted,
                token_y: token_y_sorted,
                lp_token: pool_addr,
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
                token_x: token_x_sorted,
                token_y: token_y_sorted,
                creator: owner_addr,
                lp_token_supply: initial_lp_token,
                reserve_x: amount_x_sorted,
                reserve_y: amount_y_sorted,
                platform_fee_percent: dex_config.platform_fee_percent,
                platform_fee_recipient: dex_config.platform_fee_recipient,
                fee_percent: dex_config.default_fee_percent,
                created_at: timestamp::now_seconds()
            }
        );
    }

    /// Add liquidity to an existing pool. Amounts and mins are in the caller's token order.
    public entry fun add_liquidity(
        provider: &signer,
        token_x: address,
        token_y: address,
        amount_x_desired: u64,
        amount_y_desired: u64,
        amount_x_min: u64,
        amount_y_min: u64,
        deadline: u64
    ) acquires LiquidityPool {
        assert!(timestamp::now_seconds() <= deadline, E_DEADLINE_EXCEEDED);
        assert!(
            amount_x_desired > 0 && amount_y_desired > 0, E_ZERO_AMOUNT
        );

        let pool_addr = get_pool_object_address(token_x, token_y);
        let pool = borrow_global_mut<LiquidityPool>(pool_addr);

        let (
            token_x_sorted, token_y_sorted, amount_x_sorted, amount_y_sorted
        ) = sort_token(
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

        let (user_amount_x, user_amount_y) =
            if (token_x == token_x_sorted) {
                (amount_x, amount_y)
            } else {
                (amount_y, amount_x)
            };
        assert!(user_amount_x >= amount_x_min, E_INSUFFICIENT_INPUT_AMOUNT);
        assert!(user_amount_y >= amount_y_min, E_INSUFFICIENT_INPUT_AMOUNT);

        let lp_tokens_to_mint =
            calculate_lp_tokens_for_deposit(
                amount_x,
                amount_y,
                pool.reserve_x,
                pool.reserve_y,
                pool.lp_token_supply
            );
        assert!(lp_tokens_to_mint > 0, E_INSUFFICIENT_LIQUIDITY);

        pool.reserve_x += amount_x;
        pool.reserve_y += amount_y;
        pool.lp_token_supply += lp_tokens_to_mint;

        let provider_addr = address_of(provider);
        primary_fungible_store::transfer(
            provider,
            address_to_object<Metadata>(token_x_sorted),
            pool_addr,
            amount_x
        );
        primary_fungible_store::transfer(
            provider,
            address_to_object<Metadata>(token_y_sorted),
            pool_addr,
            amount_y
        );

        let lp_asset = fungible_asset::mint(&pool.mint_ref, lp_tokens_to_mint);
        primary_fungible_store::deposit(provider_addr, lp_asset);

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

    /// Remove liquidity and receive both tokens. Mins are in the caller's token order.
    public entry fun remove_liquidity(
        provider: &signer,
        token_x_d: address,
        token_y_d: address,
        lp_amount: u64,
        amount_x_min: u64,
        amount_y_min: u64,
        deadline: u64
    ) acquires LiquidityPool {
        assert!(timestamp::now_seconds() <= deadline, E_DEADLINE_EXCEEDED);
        assert!(lp_amount > 0, E_ZERO_AMOUNT);

        let pool_addr = get_pool_object_address(token_x_d, token_y_d);
        let pool = borrow_global_mut<LiquidityPool>(pool_addr);
        assert!(pool.lp_token_supply >= lp_amount, E_INSUFFICIENT_LIQUIDITY);

        let (amount_x, amount_y) =
            calculate_withdrawal_amounts(
                lp_amount,
                pool.reserve_x,
                pool.reserve_y,
                pool.lp_token_supply
            );
        assert!(
            amount_x > 0 && amount_y > 0, E_INSUFFICIENT_LIQUIDITY
        );

        let (user_amount_x, user_amount_y) =
            if (token_x_d == pool.token_x) {
                (amount_x, amount_y)
            } else {
                (amount_y, amount_x)
            };
        assert!(user_amount_x >= amount_x_min, E_INSUFFICIENT_OUTPUT_AMOUNT);
        assert!(user_amount_y >= amount_y_min, E_INSUFFICIENT_OUTPUT_AMOUNT);

        let provider_addr = address_of(provider);
        let pool_signer = &object::generate_signer_for_extending(&pool.extend_ref);

        let lp_token =
            primary_fungible_store::withdraw(
                provider, address_to_object<Metadata>(pool.lp_token), lp_amount
            );
        fungible_asset::burn(&pool.burn_ref, lp_token);

        primary_fungible_store::transfer(
            pool_signer,
            address_to_object<Metadata>(pool.token_x),
            provider_addr,
            amount_x
        );
        primary_fungible_store::transfer(
            pool_signer,
            address_to_object<Metadata>(pool.token_y),
            provider_addr,
            amount_y
        );

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

    /// Swap exact `amount_in` of token_in for token_out through their direct pool
    public entry fun swap(
        trader: &signer,
        token_in: address,
        token_out: address,
        amount_in: u64,
        amount_out_min: u64,
        deadline: u64
    ) acquires DexConfig, LiquidityPool {
        assert!(timestamp::now_seconds() <= deadline, E_DEADLINE_EXCEEDED);
        assert!(amount_in > 0, E_INSUFFICIENT_INPUT_AMOUNT);

        let trader_addr = address_of(trader);
        let fa_in =
            primary_fungible_store::withdraw(
                trader, address_to_object<Metadata>(token_in), amount_in
            );
        let fa_out = swap_fa(trader_addr, token_in, token_out, fa_in);
        assert!(
            fungible_asset::amount(&fa_out) >= amount_out_min,
            E_INSUFFICIENT_OUTPUT_AMOUNT
        );
        primary_fungible_store::deposit(trader_addr, fa_out);
    }

    /// Swap exact `amount_in` along `path` (e.g. [A, DYNA, B]); slippage checked on final output
    public entry fun swap_exact_in_route(
        trader: &signer,
        path: vector<address>,
        amount_in: u64,
        amount_out_min: u64,
        deadline: u64
    ) acquires DexConfig, LiquidityPool {
        assert!(timestamp::now_seconds() <= deadline, E_DEADLINE_EXCEEDED);
        assert!(amount_in > 0, E_INSUFFICIENT_INPUT_AMOUNT);
        assert_valid_route(&path);

        let trader_addr = address_of(trader);
        let fa =
            primary_fungible_store::withdraw(
                trader,
                address_to_object<Metadata>(path[0]),
                amount_in
            );
        let i = 0;
        let hops = path.length() - 1;
        while (i < hops) {
            fa = swap_fa(trader_addr, path[i], path[i + 1], fa);
            i += 1;
        };
        assert!(
            fungible_asset::amount(&fa) >= amount_out_min,
            E_INSUFFICIENT_OUTPUT_AMOUNT
        );
        primary_fungible_store::deposit(trader_addr, fa);
    }

    /// Swap `fa_in` (token_in) through the token_in/token_out pool and return token_out.
    /// The platform fee is split off `fa_in`; the swap fee stays in the pool reserves.
    fun swap_fa(
        trader_addr: address,
        token_in: address,
        token_out: address,
        fa_in: FungibleAsset
    ): FungibleAsset acquires DexConfig, LiquidityPool {
        let amount_in = fungible_asset::amount(&fa_in);
        assert!(amount_in > 0, E_INSUFFICIENT_INPUT_AMOUNT);

        let dex_config = borrow_global<DexConfig>(get_dex_object_address());
        let pool_addr = get_pool_object_address(token_in, token_out);
        let pool = borrow_global_mut<LiquidityPool>(pool_addr);

        let is_x_in = token_in == pool.token_x;
        let (reserve_in, reserve_out) =
            if (is_x_in) {
                (pool.reserve_x, pool.reserve_y)
            } else {
                (pool.reserve_y, pool.reserve_x)
            };
        assert!(
            reserve_in > 0 && reserve_out > 0, E_INSUFFICIENT_LIQUIDITY
        );
        assert!(
            (amount_in as u128)
                <= (reserve_in as u128) * (MAX_SINGLE_SWAP_PERCENT as u128)
                    / (FEE_DENOMINATOR as u128),
            E_EXCESSIVE_SWAP
        );

        let (amount_out, swap_fee, platform_fee) =
            get_amount_out_with_fees(
                amount_in,
                reserve_in,
                reserve_out,
                dex_config.default_fee_percent,
                dex_config.platform_fee_percent
            );
        assert!(amount_out > 0, E_INSUFFICIENT_OUTPUT_AMOUNT);

        if (platform_fee > 0) {
            let fee_fa = fungible_asset::extract(&mut fa_in, platform_fee);
            primary_fungible_store::deposit(dex_config.platform_fee_recipient, fee_fa);
        };
        let added_to_reserve = fungible_asset::amount(&fa_in);
        primary_fungible_store::deposit(pool_addr, fa_in);

        if (is_x_in) {
            pool.reserve_x += added_to_reserve;
            pool.reserve_y -= amount_out;
        } else {
            pool.reserve_y += added_to_reserve;
            pool.reserve_x -= amount_out;
        };

        let pool_signer = &object::generate_signer_for_extending(&pool.extend_ref);
        let fa_out =
            primary_fungible_store::withdraw(
                pool_signer, address_to_object<Metadata>(token_out), amount_out
            );

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
        fa_out
    }

    //
    // Public  Functions
    //
    #[view]
    /// Get `pool` object account address; aborts if the pool does not exist
    public fun get_pool_object_address(token_x: address, token_y: address): address {
        let pool_addr = compute_pool_address(token_x, token_y);
        assert_pool_exist(&pool_addr);
        pool_addr
    }

    #[view]
    /// Deterministic pool address for a token pair (pool may not exist yet)
    public fun compute_pool_address(token_x: address, token_y: address): address {
        let seed = generate_pool_seed(&token_x, &token_y);
        object::create_object_address(&get_dex_object_address(), seed)
    }

    #[view]
    public fun pool_exists(token_x: address, token_y: address): bool {
        exists<LiquidityPool>(compute_pool_address(token_x, token_y))
    }

    #[view]
    public fun get_lp_address(pool_address: address): address acquires LiquidityPool {
        assert_pool_exist(&pool_address);
        borrow_global<LiquidityPool>(pool_address).lp_token
    }

    #[view]
    /// Minimum amounts for `add_liquidity` given a slippage percent (0..=100)
    public fun calculate_min_amounts(
        pool_addr: address,
        amount_x_desired: u64,
        amount_y_desired: u64,
        slippage_percent: u64
    ): (u64, u64) acquires LiquidityPool {
        assert!(slippage_percent <= 100, E_INVALID_SLIPPAGE);
        assert_pool_exist(&pool_addr);
        let pool = borrow_global<LiquidityPool>(pool_addr);
        let (expected_x, expected_y) =
            calculate_optimal_add_amounts(
                pool.reserve_x,
                pool.reserve_y,
                amount_x_desired,
                amount_y_desired
            );
        (
            mul_div(expected_x, 100 - slippage_percent, 100),
            mul_div(expected_y, 100 - slippage_percent, 100)
        )
    }

    #[view]
    /// Get `dex` admin object account address
    public fun get_dex_object_address(): address {
        object::create_object_address(&CA, DEX_ACCOUNT_SEED)
    }

    #[view]
    /// Output amount for `amount_in` against raw reserves, using current fees
    public fun get_amount_out(
        amount_in: u64, reserve_in: u64, reserve_out: u64
    ): u64 acquires DexConfig {
        assert!(amount_in > 0, E_INSUFFICIENT_INPUT_AMOUNT);
        assert!(
            reserve_in > 0 && reserve_out > 0, E_INSUFFICIENT_LIQUIDITY
        );

        let dex_addr = get_dex_object_address();
        assert_dex_exist(&dex_addr);
        let dex = borrow_global<DexConfig>(dex_addr);
        let (amount_out, _, _) =
            get_amount_out_with_fees(
                amount_in,
                reserve_in,
                reserve_out,
                dex.default_fee_percent,
                dex.platform_fee_percent
            );
        amount_out
    }

    #[view]
    /// Quote a direct swap: (amount_out, swap_fee, platform_fee)
    public fun quote_swap(
        token_in: address, token_out: address, amount_in: u64
    ): (u64, u64, u64) acquires DexConfig, LiquidityPool {
        let pool_addr = get_pool_object_address(token_in, token_out);
        let pool = borrow_global<LiquidityPool>(pool_addr);
        let dex = borrow_global<DexConfig>(get_dex_object_address());
        let (reserve_in, reserve_out) =
            if (token_in == pool.token_x) {
                (pool.reserve_x, pool.reserve_y)
            } else {
                (pool.reserve_y, pool.reserve_x)
            };
        get_amount_out_with_fees(
            amount_in,
            reserve_in,
            reserve_out,
            dex.default_fee_percent,
            dex.platform_fee_percent
        )
    }

    #[view]
    /// Quote the final output of `swap_exact_in_route`
    public fun quote_route(
        path: vector<address>, amount_in: u64
    ): u64 acquires DexConfig, LiquidityPool {
        assert_valid_route(&path);
        let amount = amount_in;
        let i = 0;
        let hops = path.length() - 1;
        while (i < hops) {
            let (out, _, _) = quote_swap(path[i], path[i + 1], amount);
            amount = out;
            i += 1;
        };
        amount
    }

    #[view]
    /// (tokenA, tokenB) amounts that `lp_tokens` currently redeem for
    public fun calculate_lp_value(
        pool_addr: address, lp_tokens: u64
    ): (u64, u64) acquires LiquidityPool {
        assert_pool_exist(&pool_addr);
        let pool = borrow_global<LiquidityPool>(pool_addr);
        (
            mul_div(pool.reserve_x, lp_tokens, pool.lp_token_supply),
            mul_div(pool.reserve_y, lp_tokens, pool.lp_token_supply)
        )
    }

    /// Sort tokens by address to ensure consistent ordering
    public fun sort_token(
        token_x: address, token_y: address, amount_x: u64, amount_y: u64
    ): (address, address, u64, u64) {
        let cmp = comparator::compare(&token_x, &token_y);

        if (cmp.is_smaller_than()) {
            (
                token_x, token_y, amount_x, amount_y
            )
        } else {
            (
                token_y, token_x, amount_y, amount_x
            )
        }
    }

    /// Optimal deposit amounts that keep the pool ratio unchanged
    public fun calculate_optimal_add_amounts(
        reserve_x: u64,
        reserve_y: u64,
        amount_x_desired: u64,
        amount_y_desired: u64
    ): (u64, u64) {
        if (reserve_x == 0 && reserve_y == 0) {
            return (amount_x_desired, amount_y_desired)
        };

        let amount_y_optimal = mul_div(amount_x_desired, reserve_y, reserve_x);
        if (amount_y_optimal <= amount_y_desired) {
            return (amount_x_desired, amount_y_optimal)
        };

        let amount_x_optimal = mul_div(amount_y_desired, reserve_x, reserve_y);
        (amount_x_optimal, amount_y_desired)
    }

    //
    // Internal Functions
    //

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

    /// Initial LP supply: geometric mean of the deposits, computed in u128
    fun calculate_initial_lp_tokens(amount_x: u64, amount_y: u64): u64 {
        let lp = math128::sqrt((amount_x as u128) * (amount_y as u128));
        assert!(lp <= (MAX_U64 as u128), E_LARGE_VALUES);
        lp as u64
    }

    /// LP tokens for a proportional deposit (min of both sides)
    fun calculate_lp_tokens_for_deposit(
        amount_x: u64,
        amount_y: u64,
        reserve_x: u64,
        reserve_y: u64,
        total_supply: u64
    ): u64 {
        let lp_from_x = mul_div(amount_x, total_supply, reserve_x);
        let lp_from_y = mul_div(amount_y, total_supply, reserve_y);
        if (lp_from_x < lp_from_y) {
            lp_from_x
        } else {
            lp_from_y
        }
    }

    /// Calculate withdrawal amounts based on LP tokens
    fun calculate_withdrawal_amounts(
        lp_tokens: u64, reserve_x: u64, reserve_y: u64, total_supply: u64
    ): (u64, u64) {
        assert!(lp_tokens <= total_supply, E_INSUFFICIENT_LIQUIDITY);
        assert!(
            reserve_x > 0 && reserve_y > 0, E_INSUFFICIENT_LIQUIDITY
        );
        (
            mul_div(lp_tokens, reserve_x, total_supply),
            mul_div(lp_tokens, reserve_y, total_supply)
        )
    }

    /// Get amount out with call fees calculated: (amount_out, swap_fee, platform_fee)
    fun get_amount_out_with_fees(
        amount_in: u64,
        reserve_in: u64,
        reserve_out: u64,
        fee_percent: u64, // 1 = 0.01%
        platform_fee_percent: u64 // 2 = 0.02%
    ): (u64, u64, u64) {
        let platform_fee = mul_div(amount_in, platform_fee_percent, FEE_DENOMINATOR);
        let swap_fee = mul_div(amount_in, fee_percent, FEE_DENOMINATOR);
        let amount_in_after_fees = amount_in - platform_fee - swap_fee;

        let numerator = (amount_in_after_fees as u256) * (reserve_out as u256);
        let denominator = (reserve_in as u256) + (amount_in_after_fees as u256);
        let amount_out = (numerator / denominator) as u64;

        (amount_out, swap_fee, platform_fee)
    }

    /// floor(a * b / c) without intermediate overflow
    fun mul_div(a: u64, b: u64, c: u64): u64 {
        (((a as u128) * (b as u128)) / (c as u128)) as u64
    }

    fun emit_fee_config(config: &DexConfig) {
        event::emit(
            FeeConfigUpdatedEvent {
                default_fee_percent: config.default_fee_percent,
                platform_fee_percent: config.platform_fee_percent,
                platform_fee_recipient: config.platform_fee_recipient
            }
        );
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
    public fun get_total_supply(pool_address: address): u64 acquires LiquidityPool {
        assert_pool_exist(&pool_address);
        borrow_global<LiquidityPool>(pool_address).lp_token_supply
    }

    #[view]
    /// (token_x, token_y, lp_token) of a pool, tokens in sorted order
    public fun get_pool_tokens(
        pool_address: address
    ): (address, address, address) acquires LiquidityPool {
        assert_pool_exist(&pool_address);
        let pool = borrow_global<LiquidityPool>(pool_address);
        (pool.token_x, pool.token_y, pool.lp_token)
    }

    #[view]
    /// View Pool info
    /// # Returns
    /// (lp_token, reserve_x, reserve_y, lp_token_supply, fee_percent, platform_fee_percent, platform_fee_recipient)
    public fun get_pool_info(
        pool_address: address
    ): (
        address, u64, u64, u64, u64, u64, address
    ) acquires DexConfig, LiquidityPool {
        assert_pool_exist(&pool_address);
        let dex = borrow_global<DexConfig>(get_dex_object_address());
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

    #[view]
    /// (default_fee_percent, platform_fee_percent, platform_fee_recipient)
    public fun get_fee_config(): (u64, u64, address) acquires DexConfig {
        let dex = borrow_global<DexConfig>(get_dex_object_address());
        (dex.default_fee_percent, dex.platform_fee_percent, dex.platform_fee_recipient)
    }

    #[view]
    public fun get_pools_count(): u64 acquires DexConfig {
        borrow_global<DexConfig>(get_dex_object_address()).total_pools
    }

    #[view]
    /// Pool addresses, oldest first. `limit` is capped at `MAX_PAGE_SIZE`.
    public fun get_pools(offset: u64, limit: u64): vector<address> acquires DexConfig {
        let dex = borrow_global<DexConfig>(get_dex_object_address());
        let page = vector::empty<address>();
        let total = dex.total_pools;
        if (offset >= total) return page;
        if (limit > MAX_PAGE_SIZE) {
            limit = MAX_PAGE_SIZE
        };
        let end =
            if (limit > total - offset) { total }
            else {
                offset + limit
            };
        let i = offset;
        while (i < end) {
            // pools are keyed 1..=total_pools
            page.push_back(*dex.pools.borrow(i + 1));
            i += 1;
        };
        page
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

    /// Check user is platform admin
    fun assert_platform_admin(admin_addr: &address) {
        assert!(*admin_addr == CA, E_NOT_AN_ADMIN);
    }

    fun assert_valid_route(path: &vector<address>) {
        let len = path.length();
        assert!(
            len >= 2 && len <= MAX_ROUTE_LENGTH, E_INVALID_ROUTE
        );
        let i = 0;
        while (i + 1 < len) {
            assert!(path[i] != path[i + 1], E_INVALID_ROUTE);
            i += 1;
        };
    }

    //
    // Test Functions
    //
    #[test_only]
    public fun test_init_dex(admin: &signer) {
        init_module(admin);
    }
}
