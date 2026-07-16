#[test_only]
module stealth::stealth_registry_tests;

use stealth::stealth_registry::{Self, Registry};
use sui::test_scenario as ts;

const ALICE: address = @0xA;

/// Build a 33-byte vector filled with `fill` (a valid compressed-pubkey length).
fun pk33(fill: u8): vector<u8> {
    let mut v = vector[];
    let mut i = 0u64;
    while (i < 33) {
        v.push_back(fill);
        i = i + 1;
    };
    v
}

#[test]
fun register_resolve_roundtrip() {
    let mut scenario = ts::begin(ALICE);
    {
        stealth_registry::init_for_testing(scenario.ctx());
    };

    scenario.next_tx(ALICE);
    {
        let mut reg = scenario.take_shared<Registry>();

        stealth_registry::register(&mut reg, 1, pk33(1), pk33(2), scenario.ctx());

        assert!(stealth_registry::has(&reg, ALICE), 100);
        let meta = stealth_registry::resolve(&reg, ALICE);
        assert!(stealth_registry::scheme_id(meta) == 1, 101);
        assert!(stealth_registry::spend_pubkey(meta) == pk33(1), 102);
        assert!(stealth_registry::view_pubkey(meta) == pk33(2), 103);

        ts::return_shared(reg);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = stealth_registry::EInvalidPubkeyLength)]
fun register_wrong_length_aborts() {
    let mut scenario = ts::begin(ALICE);
    {
        stealth_registry::init_for_testing(scenario.ctx());
    };

    scenario.next_tx(ALICE);
    {
        let mut reg = scenario.take_shared<Registry>();

        // spend_pubkey is empty (length 0 != 33) -> must abort.
        let bad: vector<u8> = vector[];
        stealth_registry::register(&mut reg, 1, bad, pk33(2), scenario.ctx());

        ts::return_shared(reg);
    };

    scenario.end();
}
