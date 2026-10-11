// Out-of-range counts and ids in the generated simulation and layout
// modules (#410).
//
// Before #410 these inputs indexed past a fixed-size array or divided by
// zero, so the generated Rust panicked (and the C and Zig backends read out
// of bounds or trapped). The specs now reject an out-of-range node id and
// clamp counts to the array length; these tests call the generated
// gen/rust modules with the inputs from the issue table.

#[allow(unused, clippy::all)]
#[path = "../gen/rust/network_simulator.rs"]
mod network_simulator;
#[allow(unused, clippy::all)]
#[path = "../gen/rust/topology_visualizer.rs"]
mod topology_visualizer;
#[allow(unused, clippy::all)]
#[path = "../gen/rust/traffic_animator.rs"]
mod traffic_animator;

#[test]
fn inject_fault_rejects_a_node_id_past_the_array() {
    use network_simulator::*;
    let states = [0u32; MAX_NODES as usize];
    assert_eq!(inject_fault(EVENT_NODE_FAILURE, MAX_NODES - 1, states), 1);
    for target_id in [MAX_NODES, MAX_NODES + 1, u32::MAX] {
        assert_eq!(
            inject_fault(EVENT_NODE_FAILURE, target_id, states),
            0,
            "target_id {target_id}"
        );
    }
    // A link failure does not index node_states, so any id is accepted.
    assert_eq!(inject_fault(EVENT_LINK_FAILURE, u32::MAX, states), 1);
}

#[test]
fn update_animation_packets_clamps_the_count_to_max_packets() {
    use traffic_animator::*;
    // Slot 0 has finished (progress 100); the others start at 0.
    let mut packets = [0u32; MAX_PACKETS as usize];
    packets[0] = create_anim_packet(1, 2, 3, 100);
    let full = update_animation_packets(packets, MAX_PACKETS, 10);
    let updated = MAX_PACKETS - 1;
    assert_eq!(full, (updated << 24) | (1 << 16) | (MAX_PACKETS << 8));
    for packet_count in [MAX_PACKETS + 1, 1000, u32::MAX] {
        assert_eq!(
            update_animation_packets(packets, packet_count, 10),
            full,
            "packet_count {packet_count}"
        );
    }
    // In-range counts are unchanged.
    assert_eq!(
        update_animation_packets(packets, 2, 10),
        (1 << 24) | (1 << 16) | (2 << 8)
    );
}

#[test]
fn circular_layout_clamps_the_count_to_max_nodes() {
    use topology_visualizer::*;
    let nodes = [0u32; MAX_NODES as usize];
    for (node_count, placed) in [(0, 0), (1, 1), (32, 32), (33, 32), (u32::MAX, 32)] {
        assert_eq!(
            calculate_circular_layout(nodes, node_count),
            placed,
            "node_count {node_count}"
        );
    }
}

#[test]
fn hierarchical_layout_never_divides_by_zero_and_clamps_the_count() {
    use topology_visualizer::*;
    let nodes = [0u32; MAX_NODES as usize];
    let edges = [0u32; MAX_EDGES as usize];
    for (node_count, placed) in [
        (0, 0),
        (1, 1),
        (2, 2),
        (3, 3),
        (4, 4),
        (32, 32),
        (33, 32),
        (u32::MAX, 32),
    ] {
        assert_eq!(
            calculate_hierarchical_layout(nodes, edges, node_count, 0),
            placed,
            "node_count {node_count}"
        );
    }
}

#[test]
fn apply_layout_routes_out_of_range_counts_to_the_clamped_layouts() {
    use topology_visualizer::*;
    let nodes = [0u32; MAX_NODES as usize];
    let edges = [0u32; MAX_EDGES as usize];
    let circular = create_layout_params(ALGORITHM_CIRCULAR, 0, 0, 0);
    let hierarchical = create_layout_params(ALGORITHM_HIERARCHICAL, 0, 0, 0);
    assert_eq!(apply_layout(nodes, edges, 33, 0, circular), 32);
    assert_eq!(apply_layout(nodes, edges, 3, 0, hierarchical), 3);
}
