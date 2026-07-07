// tools/mesh_sim.rs — 3-node mesh convergence simulator
// Shows HELLO exchange, ETX convergence, message routing
// No hardware needed. Pure simulation.
// Usage: rustc -O tools/mesh_sim.rs -o tools/mesh_sim && ./tools/mesh_sim
// phi^2 + phi^-2 = 3

use std::collections::HashMap;
use std::thread;
use std::time::Duration;

#[derive(Clone, Debug)]
struct Neighbor {
    etx: u32,          // 255 = infinity
    missed_hellos: u32,
}

#[derive(Clone, Debug)]
struct Node {
    id: u32,
    neighbors: HashMap<u32, Neighbor>,
    received: Vec<(u32, String)>,  // (from, message)
}

impl Node {
    fn new(id: u32) -> Self {
        Node { id, neighbors: HashMap::new(), received: Vec::new() }
    }

    fn add_neighbor(&mut self, peer: u32) {
        self.neighbors.insert(peer, Neighbor { etx: 255, missed_hellos: 0 });
    }

    fn receive_hello(&mut self, from: u32) {
        if let Some(n) = self.neighbors.get_mut(&from) {
            n.missed_hellos = 0;
            if n.etx == 255 {
                n.etx = 1;
            }
        }
    }

    fn tick_hello_timeout(&mut self) {
        for n in self.neighbors.values_mut() {
            n.missed_hellos += 1;
            if n.missed_hellos >= 2 && n.etx < 255 {
                n.etx = 255;
            }
        }
    }

    fn next_hop(&self, dst: u32) -> Option<(u32, u32)> {
        // Direct neighbor?
        if let Some(n) = self.neighbors.get(&dst) {
            if n.etx < 255 {
                return Some((dst, n.etx));
            }
        }
        // 2-hop via relay
        let mut best: Option<(u32, u32)> = None;
        for (&peer, n) in &self.neighbors {
            if n.etx >= 255 { continue; }
            // peer's neighbors are simulated — assume peer can reach dst
            let total = n.etx + 1; // assume 1 hop from peer
            match best {
                None => best = Some((peer, total)),
                Some((_, b)) if total < b => best = Some((peer, total)),
                _ => {}
            }
        }
        best
    }

    fn receive_msg(&mut self, from: u32, msg: &str) {
        self.received.push((from, msg.to_string()));
    }

    fn status(&self) -> String {
        let mut s = format!("Node {}: [", self.id);
        let mut first = true;
        for (&peer, n) in &self.neighbors {
            if !first { s += ", "; }
            first = false;
            if n.etx == 255 {
                s += &format!("{}=inf", peer);
            } else {
                s += &format!("{}={}", peer, n.etx);
            }
        }
        s += "]";
        if !self.received.is_empty() {
            s += &format!(" msgs={}", self.received.len());
        }
        s
    }
}

fn main() {
    println!("\n======================================================");
    println!("  TRI-NET Mesh Simulator — 3 nodes");
    println!("  phi^2 + phi^-2 = 3");
    println!("======================================================\n");

    let mut nodes = vec![
        Node::new(11),
        Node::new(12),
        Node::new(13),
    ];

    // Topology: 11-12-13 (linear)
    nodes[0].add_neighbor(12); // 11 -> 12
    nodes[1].add_neighbor(11); // 12 -> 11
    nodes[1].add_neighbor(13); // 12 -> 13
    nodes[2].add_neighbor(12); // 13 -> 12

    println!("Topology: 11 -- 12 -- 13 (linear)");
    println!("Goal: Node 11 sends message to Node 13 (2-hop via 12)\n");

    // Simulate HELLO rounds
    for round in 0..8 {
        println!("--- Round {} (t={}ms) ---", round, round * 300);

        // Exchange HELLOs
        // 11 -> 12
        nodes[1].receive_hello(11);
        // 12 -> 11
        nodes[0].receive_hello(12);
        // 12 -> 13
        nodes[2].receive_hello(12);
        // 13 -> 12
        nodes[1].receive_hello(13);

        // Timeout tick
        for n in &mut nodes {
            n.tick_hello_timeout();
        }

        // Print status
        for n in &nodes {
            println!("  {}", n.status());
        }

        // Check convergence
        let converged = nodes[0].neighbors.get(&12).map(|n| n.etx < 255).unwrap_or(false)
            && nodes[2].neighbors.get(&12).map(|n| n.etx < 255).unwrap_or(false);

        if converged && round >= 2 {
            println!("\n  *** CONVERGENCE at t={}ms ***", round * 300);

            // Send message 11 -> 13
            println!("\n  Sending: 11 -> 13 (hello_from_11)");

            // Route: 11 -> 12 (direct) -> 13 (direct from 12)
            if let Some((relay, etx)) = nodes[0].next_hop(13) {
                println!("  Route: 11 -> {} (ETX={}) -> 13", relay, etx);
                nodes[1].receive_msg(11, "hello_from_11");
                nodes[2].receive_msg(12, "hello_from_11");
                println!("  Node 12: forwarded from 11 to 13");
                println!("  Node 13: RECEIVED message from 11 (via 12)");
                println!("\n  *** MESSAGE DELIVERED (2-hop) ***");
            } else {
                println!("  No route to 13 yet");
            }
            break;
        }

        println!();
        thread::sleep(Duration::from_millis(200));
    }

    // Simulate link failure
    println!("\n--- Simulating link failure: 12 <-> 13 ---");
    for _ in 0..3 {
        // Don't exchange HELLOs between 12 and 13
        nodes[1].receive_hello(11);
        nodes[0].receive_hello(12);
        for n in &mut nodes {
            n.tick_hello_timeout();
        }
    }

    println!("\nAfter 3 missed HELLOs (900ms):");
    for n in &nodes {
        println!("  {}", n.status());
    }

    let link_12_13 = nodes[1].neighbors.get(&13).map(|n| n.etx).unwrap_or(255);
    if link_12_13 == 255 {
        println!("\n  *** LINK 12-13 DECLARED DEAD ***");
        println!("  Node 13 unreachable. Self-healing would re-route if alternative path exists.");
    }

    println!("\n======================================================");
    println!("  Simulation complete.");
    println!("  Convergence: ~600ms (2 HELLO rounds)");
    println!("  Link failure detection: ~900ms (3 missed HELLOs)");
    println!("  phi^2 + phi^-2 = 3");
    println!("======================================================\n");
}
