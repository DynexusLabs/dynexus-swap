#[test_only]
module dynexus_swap::dex_v2_tests {

    use std::signer::address_of;
    use std::string::utf8;
    use aptos_framework::account::create_account_for_test;
    use aptos_framework::genesis;
    use aptos_framework::timestamp;
    use dynexus_forge::token_factory;
    use dynexus_forge::token_factory_test::{Self, balance_of};
    use dynexus_swap::dex;

    const MAX_U64: u64 = 18446744073709551615;
    const ONE: u64 = 100_000_000; // 1 token at 8 decimals

    /// Sets up forge + dex and returns (provider, tokenA, tokenB, tokenC); provider holds 1M of each.
    fun setup(admin: &signer): (signer, address, address, address) {
        genesis::setup();
        create_account_for_test(address_of(admin));
        token_factory_test::setup_token_factory(address_of(admin));
        dex::test_init_dex(admin);

        let provider = create_account_for_test(@0xbabe);
        let a = new_token(admin, b"Alpha", b"ALP");
        let b = new_token(admin, b"Beta", b"BET");
        let c = new_token(admin, b"Gamma", b"GAM");
        let supply = 1_000_000 * ONE;
        token_factory::mint_token(admin, @0xbabe, a, supply);
        token_factory::mint_token(admin, @0xbabe, b, supply);
        token_factory::mint_token(admin, @0xbabe, c, supply);
        (provider, a, b, c)
    }

    fun new_token(admin: &signer, name: vector<u8>, symbol: vector<u8>): address {
        let (_, _, addr) =
            token_factory::create_test_token(
                admin,
                utf8(name),
                utf8(symbol),
                8,
                0,
                utf8(b""),
                utf8(b""),
                0
            );
        addr
    }

    fun deadline(): u64 {
        timestamp::now_seconds() + 60
    }

    #[test(admin = @dynexus_swap)]
    /// Previously aborted with E_LARGE_VALUES: x*y overflowed u64 before sqrt.
    fun test_create_large_pool(admin: &signer) {
        let (provider, a, b, _) = setup(admin);
        dex::create_pool(&provider, a, b, 500_000 * ONE, 250_000 * ONE);
        let pool = dex::get_pool_object_address(a, b);
        let (rx, ry) = dex::get_pool_reserves(pool);
        assert!(rx + ry == 750_000 * ONE, 1);
        assert!(dex::get_total_supply(pool) > 0, 2);
    }

    #[test(admin = @dynexus_swap)]
    fun test_minimum_liquidity_locked_in_pool(admin: &signer) {
        let (provider, a, b, _) = setup(admin);
        dex::create_pool(&provider, a, b, 100 * ONE, 100 * ONE);
        let pool = dex::get_pool_object_address(a, b);
        let lp = dex::get_lp_address(pool);
        let supply = dex::get_total_supply(pool);
        assert!(balance_of(pool, lp) == 1000, 1);
        assert!(balance_of(@0xbabe, lp) == supply - 1000, 2);

        // Provider can withdraw everything they own; locked LP keeps reserves non-zero
        dex::remove_liquidity(&provider, a, b, supply - 1000, 0, 0, deadline());
        let (rx, ry) = dex::get_pool_reserves(pool);
        assert!(rx > 0 && ry > 0, 3);
    }

    #[test(admin = @dynexus_swap)]
    #[expected_failure(abort_code = dex::E_INVALID_INITIAL_LIQUIDITY)]
    fun test_pool_must_exceed_minimum_liquidity(admin: &signer) {
        let (provider, a, b, _) = setup(admin);
        dex::create_pool(&provider, a, b, 1000, 1000);
    }

    #[test(admin = @dynexus_swap)]
    /// Previously platform fees were sent to the dex object, which had no withdraw path.
    fun test_platform_fee_goes_to_admin_recipient(admin: &signer) {
        let (provider, a, b, _) = setup(admin);
        dex::create_pool(&provider, a, b, 1000 * ONE, 1000 * ONE);
        let (_, _, recipient) = dex::get_fee_config();
        assert!(recipient == @dynexus_swap, 1);

        let before = balance_of(recipient, a);
        let (_, _, platform_fee) = dex::quote_swap(a, b, 10 * ONE);
        dex::swap(&provider, a, b, 10 * ONE, 0, deadline());
        assert!(
            balance_of(recipient, a) == before + platform_fee, 2
        );
    }

    #[test(admin = @dynexus_swap)]
    fun test_admin_updates_fees_and_recipient(admin: &signer) {
        let (provider, a, b, _) = setup(admin);
        dex::create_pool(&provider, a, b, 1000 * ONE, 1000 * ONE);
        dex::set_fees(admin, 25, 5);
        dex::set_platform_fee_recipient(admin, @0xfee);
        let (swap_fee_bps, platform_fee_bps, recipient) = dex::get_fee_config();
        assert!(
            swap_fee_bps == 25
                && platform_fee_bps == 5
                && recipient == @0xfee, 1
        );

        let (_, swap_fee, platform_fee) = dex::quote_swap(a, b, 10_000 * 1000);
        assert!(swap_fee == 25_000 && platform_fee == 5_000, 2);
        dex::swap(&provider, a, b, 10_000 * 1000, 0, deadline());
        assert!(balance_of(@0xfee, a) == 5_000, 3);
    }

    #[test(admin = @dynexus_swap)]
    #[expected_failure(abort_code = dex::E_INVALID_FEE)]
    fun test_fee_cap(admin: &signer) {
        setup(admin);
        dex::set_fees(admin, 101, 0);
    }

    #[test(admin = @dynexus_swap)]
    #[expected_failure(abort_code = dex::E_NOT_AN_ADMIN)]
    fun test_non_admin_cannot_set_fees(admin: &signer) {
        let (provider, _, _, _) = setup(admin);
        dex::set_fees(&provider, 1, 1);
    }

    #[test(admin = @dynexus_swap)]
    fun test_quote_matches_swap(admin: &signer) {
        let (provider, a, b, _) = setup(admin);
        dex::create_pool(&provider, a, b, 1000 * ONE, 3000 * ONE);
        let (quoted, _, _) = dex::quote_swap(b, a, 50 * ONE);
        let before = balance_of(@0xbabe, a);
        dex::swap(&provider, b, a, 50 * ONE, quoted, deadline());
        assert!(balance_of(@0xbabe, a) == before + quoted, 1);
    }

    #[test(admin = @dynexus_swap)]
    fun test_route_swap_two_hops(admin: &signer) {
        let (provider, a, b, c) = setup(admin);
        dex::create_pool(&provider, a, b, 1000 * ONE, 1000 * ONE);
        dex::create_pool(&provider, b, c, 1000 * ONE, 2000 * ONE);
        assert!(!dex::pool_exists(a, c), 1);

        let path = vector[a, b, c];
        let quoted = dex::quote_route(path, 10 * ONE);
        assert!(quoted > 0, 2);

        let before_a = balance_of(@0xbabe, a);
        let before_c = balance_of(@0xbabe, c);
        dex::swap_exact_in_route(&provider, path, 10 * ONE, quoted, deadline());
        assert!(balance_of(@0xbabe, a) == before_a - 10 * ONE, 3);
        assert!(balance_of(@0xbabe, c) == before_c + quoted, 4);
    }

    #[test(admin = @dynexus_swap)]
    #[expected_failure(abort_code = dex::E_INSUFFICIENT_OUTPUT_AMOUNT)]
    fun test_route_swap_slippage(admin: &signer) {
        let (provider, a, b, c) = setup(admin);
        dex::create_pool(&provider, a, b, 1000 * ONE, 1000 * ONE);
        dex::create_pool(&provider, b, c, 1000 * ONE, 1000 * ONE);
        let path = vector[a, b, c];
        let quoted = dex::quote_route(path, 10 * ONE);
        dex::swap_exact_in_route(&provider, path, 10 * ONE, quoted + 1, deadline());
    }

    #[test(admin = @dynexus_swap)]
    #[expected_failure(abort_code = dex::E_INVALID_ROUTE)]
    fun test_route_rejects_single_token(admin: &signer) {
        let (provider, a, _, _) = setup(admin);
        dex::swap_exact_in_route(&provider, vector[a], ONE, 0, deadline());
    }

    #[test(admin = @dynexus_swap)]
    #[expected_failure(abort_code = dex::E_INVALID_ROUTE)]
    fun test_route_rejects_repeated_neighbour(admin: &signer) {
        let (provider, a, b, _) = setup(admin);
        dex::create_pool(&provider, a, b, 1000 * ONE, 1000 * ONE);
        dex::swap_exact_in_route(&provider, vector[a, a, b], ONE, 0, deadline());
    }

    #[test(admin = @dynexus_swap)]
    #[expected_failure(abort_code = dex::E_INSUFFICIENT_OUTPUT_AMOUNT)]
    fun test_remove_liquidity_slippage(admin: &signer) {
        let (provider, a, b, _) = setup(admin);
        dex::create_pool(&provider, a, b, 100 * ONE, 100 * ONE);
        let pool = dex::get_pool_object_address(a, b);
        let lp = balance_of(@0xbabe, dex::get_lp_address(pool));
        let (out_x, out_y) = dex::calculate_lp_value(pool, lp);
        dex::remove_liquidity(&provider, a, b, lp, out_x + 1, out_y, deadline());
    }

    #[test(admin = @dynexus_swap)]
    #[expected_failure(abort_code = dex::E_DEADLINE_EXCEEDED)]
    fun test_remove_liquidity_deadline(admin: &signer) {
        let (provider, a, b, _) = setup(admin);
        dex::create_pool(&provider, a, b, 100 * ONE, 100 * ONE);
        timestamp::fast_forward_seconds(100);
        dex::remove_liquidity(
            &provider,
            a,
            b,
            1,
            0,
            0,
            timestamp::now_seconds() - 1
        );
    }

    #[test(admin = @dynexus_swap)]
    fun test_remove_liquidity_mins_in_caller_order(admin: &signer) {
        let (provider, a, b, _) = setup(admin);
        dex::create_pool(&provider, a, b, 100 * ONE, 300 * ONE);
        let pool = dex::get_pool_object_address(a, b);
        let lp = balance_of(@0xbabe, dex::get_lp_address(pool)) / 2;
        let before_a = balance_of(@0xbabe, a);
        let before_b = balance_of(@0xbabe, b);
        // b is ~3x a; pass mins as (b, a) in reversed caller order
        dex::remove_liquidity(&provider, b, a, lp, 140 * ONE, 45 * ONE, deadline());
        assert!(balance_of(@0xbabe, a) - before_a >= 45 * ONE, 1);
        assert!(balance_of(@0xbabe, b) - before_b >= 140 * ONE, 2);
    }

    #[test(admin = @dynexus_swap)]
    fun test_pool_listing_views(admin: &signer) {
        let (provider, a, b, c) = setup(admin);
        assert!(dex::get_pools(0, 10).length() == 0, 1);
        dex::create_pool(&provider, a, b, 100 * ONE, 100 * ONE);
        dex::create_pool(&provider, b, c, 100 * ONE, 100 * ONE);
        dex::create_pool(&provider, a, c, 100 * ONE, 100 * ONE);

        assert!(dex::get_pools_count() == 3, 2);
        let all = dex::get_pools(0, 10);
        assert!(all.length() == 3, 3);
        assert!(all[0] == dex::compute_pool_address(a, b), 4);
        assert!(all[2] == dex::compute_pool_address(c, a), 5);
        assert!(
            dex::get_pools(1, 1) == vector[dex::get_pool_object_address(b, c)],
            6
        );
        assert!(dex::get_pools(3, 10).length() == 0, 7);
        assert!(dex::get_pools(MAX_U64, MAX_U64).length() == 0, 8);

        let (tx, ty, lp) = dex::get_pool_tokens(all[0]);
        assert!(lp == all[0], 9);
        assert!((tx == a && ty == b) || (tx == b && ty == a), 10);
    }

    #[test(admin = @dynexus_swap)]
    #[expected_failure(abort_code = dex::E_INVALID_SLIPPAGE)]
    fun test_min_amounts_rejects_slippage_over_100(admin: &signer) {
        let (provider, a, b, _) = setup(admin);
        dex::create_pool(&provider, a, b, 100 * ONE, 100 * ONE);
        dex::calculate_min_amounts(
            dex::get_pool_object_address(a, b),
            ONE,
            ONE,
            101
        );
    }
}
