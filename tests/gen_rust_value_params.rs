// Behaviour of the ten generated Rust modules that compile since #399.
//
// Their specs now copy assigned value parameters into local `var`
// bindings (or, in api_documenter, use a literal repeat count). Parameters
// are values in every backend: the generated C passes arrays as structs by
// value and the generated Zig shadows them, so a write never reaches the
// caller. These tests pin the returned values and that caller contract.

#[allow(unused, clippy::all)]
#[path = "../gen/rust/api_documenter.rs"]
mod api_documenter;
#[allow(unused, clippy::all)]
#[path = "../gen/rust/auto_config.rs"]
mod auto_config;
#[allow(unused, clippy::all)]
#[path = "../gen/rust/bandwidth_allocator.rs"]
mod bandwidth_allocator;
#[allow(unused, clippy::all)]
#[path = "../gen/rust/cache_management.rs"]
mod cache_management;
#[allow(unused, clippy::all)]
#[path = "../gen/rust/compression_engine.rs"]
mod compression_engine;
#[allow(unused, clippy::all)]
#[path = "../gen/rust/integration_framework.rs"]
mod integration_framework;
#[allow(unused, clippy::all)]
#[path = "../gen/rust/network_simulator.rs"]
mod network_simulator;
#[allow(unused, clippy::all)]
#[path = "../gen/rust/performance_profiler.rs"]
mod performance_profiler;
#[allow(unused, clippy::all)]
#[path = "../gen/rust/topology_visualizer.rs"]
mod topology_visualizer;
#[allow(unused, clippy::all)]
#[path = "../gen/rust/traffic_animator.rs"]
mod traffic_animator;

#[test]
fn flow_bandwidth_is_clamped_between_minimum_and_maximum() {
    use bandwidth_allocator::*;
    let flow = create_flow_requirement(5, PRIORITY_HIGH, 50, 100);
    for (requested, granted) in [
        (0, 50),
        (49, 50),
        (50, 50),
        (70, 70),
        (500, 500),
        (501, 500),
    ] {
        let updated = update_flow_bandwidth(flow, requested);
        assert_eq!(
            get_current_bandwidth(updated),
            granted,
            "request {requested}"
        );
        assert_eq!(get_flow_id(updated), 5);
        assert_eq!(get_flow_priority(updated), PRIORITY_HIGH);
        assert_eq!(get_min_bandwidth(updated), 50);
    }
}

fn full_cache() -> [u32; 16] {
    // Data ids 1..=16, size 10 each; slot 4 is the only cold entry.
    std::array::from_fn(|i| {
        let access_count = if i == 4 { 1 } else { 5 };
        cache_management::create_cache_entry(i as u32 + 1, access_count, 0, 10)
    })
}

#[test]
fn cache_operations_return_sizes_and_leave_the_caller_cache_unchanged() {
    use cache_management::*;
    let empty = [0u32; 16];
    let mut one = empty;
    one[3] = create_cache_entry(7, 1, 0, 30);
    let full = full_cache();
    let snapshots = (empty, one, full);

    // Empty slot: the new size is added.
    assert_eq!(add_entry(empty, 0, 7, 30), 30);
    // Already cached: the size is unchanged.
    assert_eq!(add_entry(one, 30, 7, 10), 30);
    // Not enough room: the size is unchanged.
    assert_eq!(add_entry(empty, 250, 9, 10), 250);
    // Full: the cold entry (size 10) is evicted, then 20 is added.
    assert_eq!(find_eviction_candidate(full), 4);
    assert_eq!(add_entry(full, 160, 99, 20), 170);

    assert_eq!(remove_entry(full, 160, 3), 150);
    assert_eq!(remove_entry(full, 160, 99), 160);
    assert_eq!(access_cache(full, 3), 1);
    assert_eq!(access_cache(full, 99), 0);
    age_cache(full);

    assert_eq!((empty, one, full), snapshots, "a value argument changed");
}

#[test]
fn config_bounds_accept_zero_and_the_upper_limit() {
    use auto_config::*;
    let with = |param_id: u32, value: u32| {
        let mut config = [0u32; 16];
        config[0] = create_config_param(param_id, value, 0, STATUS_APPLIED);
        config
    };
    for (param_id, limit) in [
        (PARAM_TX_POWER, 100),
        (PARAM_CHANNEL, 11),
        (PARAM_DATA_RATE, 3),
        (PARAM_RETRY_LIMIT, 7),
        (PARAM_SECURITY_LEVEL, 3),
    ] {
        assert_eq!(validate_config(with(param_id, 0), param_id), 1);
        assert_eq!(validate_config(with(param_id, limit), param_id), 1);
        assert_eq!(validate_config(with(param_id, limit + 1), param_id), 0);
    }

    let config = with(PARAM_CHANNEL, 6);
    let before = config;
    assert_eq!(set_config_value(config, PARAM_CHANNEL, 9), 1);
    assert_eq!(set_config_value(config, 200, 9), 0);
    assert_eq!(apply_config(config, PARAM_CHANNEL), 1);
    assert_eq!(apply_config(config, 200), 0);
    assert_eq!(config, before, "a value argument changed");
    // The caller still sees the old value.
    assert_eq!(get_config_value(config, PARAM_CHANNEL), 6);

    // Backup ids: 1 matches, 5 does not, and fourteen empty ids (0) match
    // the empty local entries.
    let mut local = [0u32; 16];
    local[0] = create_config_param(1, 10, 0, STATUS_APPLIED);
    local[1] = create_config_param(2, 20, 0, STATUS_APPLIED);
    let mut backup = [0u32; 16];
    backup[0] = create_config_param(1, 11, 0, STATUS_APPLIED);
    backup[1] = create_config_param(5, 50, 0, STATUS_APPLIED);
    assert_eq!(rollback_config(local, backup), 15);
}

#[test]
fn table_writes_report_success_without_touching_the_caller() {
    let dictionary = [9u32; 8];
    assert_eq!(compression_engine::update_dictionary(dictionary, 1, 7), 1);
    assert_eq!(compression_engine::update_dictionary(dictionary, 1, 8), 0);
    assert_eq!(dictionary, [9u32; 8]);

    use integration_framework::*;
    assert_eq!(TYPE_DOCUMENTATION, 2);
    let free = [0u32; 64];
    let busy = [1u32; 64];
    assert_eq!(subscribe_to_event(1, 2, free), 1);
    assert_eq!(subscribe_to_event(1, 2, busy), 0);
    let mut modules = [0u32; 16];
    modules[5] = create_module_registration(42, TYPE_TESTING, 1, STATUS_ACTIVE);
    let before = modules;
    assert_eq!(load_module(43, TYPE_NETWORK, 1, modules), 1);
    let crowded: [u32; 16] =
        std::array::from_fn(|i| create_module_registration(i as u32 + 1, 0, 0, 0));
    assert_eq!(load_module(43, TYPE_NETWORK, 1, crowded), 0);
    assert_eq!(unload_module(42, modules), 1);
    assert_eq!(unload_module(44, modules), 0);
    assert_eq!(modules, before);

    let allocations = [0u32; 64];
    let exhausted: [u32; 64] =
        std::array::from_fn(|i| performance_profiler::create_allocation(i as u32 + 1, 4, 1, 0));
    assert_eq!(
        performance_profiler::track_allocation(allocations, 7, 16, 0),
        1
    );
    assert_eq!(
        performance_profiler::track_allocation(exhausted, 7, 16, 0),
        0
    );
    assert_eq!(allocations, [0u32; 64]);
}

#[test]
fn simulation_and_layout_results_are_unchanged() {
    use network_simulator::*;
    let states = [0u32; 32];
    let failure = (EVENT_NODE_FAILURE << 4) | 3;
    assert_eq!(process_event(failure, states, states), 1);
    assert_eq!(process_event(9 << 4, states, states), 0);
    assert_eq!(inject_fault(EVENT_NODE_FAILURE, 31, states), 1);
    assert_eq!(inject_fault(EVENT_LINK_FAILURE, 0, states), 1);
    assert_eq!(inject_fault(7, 0, states), 0);
    assert_eq!(states, [0u32; 32]);

    let nodes = [0x0102_0304u32; 32];
    let edges = [0u32; 64];
    for count in [0, 1, 7, 32] {
        assert_eq!(
            topology_visualizer::calculate_circular_layout(nodes, count),
            count
        );
    }
    for count in [4, 9, 32] {
        assert_eq!(
            topology_visualizer::calculate_hierarchical_layout(nodes, edges, count, 0),
            count
        );
    }
    assert_eq!(nodes, [0x0102_0304u32; 32]);
}

#[test]
fn animation_counts_updated_and_completed_packets() {
    use traffic_animator::*;
    let mut packets = [0u32; 64];
    packets[0] = create_anim_packet(1, 2, 3, 40);
    packets[1] = create_anim_packet(2, 2, 3, 100);
    packets[2] = create_anim_packet(3, 2, 3, 95);
    let before = packets;
    // Three packets: two in flight are updated, one is already complete.
    assert_eq!(
        update_animation_packets(packets, 3, 10),
        (2 << 24) | (1 << 16) | (3 << 8)
    );
    assert_eq!(update_animation_packets(packets, 0, 10), 0);
    assert_eq!(packets, before);
}

#[test]
fn documentation_report_coverage_and_reference_count() {
    use api_documenter::*;
    let docs: [u32; 64] = std::array::from_fn(|i| create_function_doc(i as u32, 2, 1, 1000));
    let xrefs = [0u32; 64];
    for (functions, references) in [(0, 0), (1, 3), (64, 64)] {
        let report = generate_documentation_report(docs, functions, xrefs, references);
        // Every listed function is documented, so coverage is 100 percent.
        assert_eq!(report >> 24, 100);
        assert_eq!(report & 0xFF, references);
    }
}
