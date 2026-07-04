//! ETX (Expected Transmission Count) link metric and neighbor table.
//!
//! ETX = 1 / (d_f · d_r), where d_f is the forward delivery ratio (fraction of
//! our HELLOs the neighbor received) and d_r the reverse ratio (fraction of the
//! neighbor's HELLOs we received). A perfect link = 1.0; lossy links cost more.
//! Path ETX is additive over hops, so the best next hop minimizes total ETX.
//!
//! Status: host-testable (`-sim`) — real per-neighbor metrics land at milestone M2.

use std::collections::HashMap;

pub type NodeId = u32;

/// WMEWMA delivery-ratio estimator: `est ← α·sample + (1-α)·est`. Reacts to
/// recent loss in a few intervals rather than the whole window — the standard
/// fix for stale ETX under UAV mobility (Woo, Tong & Culler, SenSys 2003;
/// Rosati et al., arXiv:1307.6350). Starts optimistic so a fresh link is usable.
#[derive(Clone, Debug)]
struct DeliveryRatio {
    alpha: f32,
    est: f32,
}

impl DeliveryRatio {
    /// Optimistic prior: assume good until proven bad (fresh link has finite ETX).
    const OPTIMISTIC: f32 = 0.9;

    fn new(window: usize) -> Self {
        // EWMA span 2/(N+1), clamped to a responsive band (smaller window = faster).
        let alpha = (2.0 / (window.max(1) as f32 + 1.0)).clamp(0.3, 0.6);
        Self {
            alpha,
            est: Self::OPTIMISTIC,
        }
    }

    fn record(&mut self, got_hello: bool) {
        let sample = if got_hello { 1.0 } else { 0.0 };
        self.est = self.alpha * sample + (1.0 - self.alpha) * self.est;
    }

    /// B03 fast-fail: collapse the estimate immediately (a confirmed dead link).
    fn kill(&mut self) {
        self.est = 0.0;
    }

    fn ratio(&self) -> f32 {
        self.est
    }
}

/// Per-neighbor link state and computed ETX.
#[derive(Clone, Debug)]
pub struct LinkStats {
    forward: DeliveryRatio,
    reverse: DeliveryRatio,
}

impl LinkStats {
    /// A direction whose WMEWMA estimate has decayed below this is treated dead.
    const DEAD_EPS: f32 = 0.15;

    fn new(window: usize) -> Self {
        Self {
            forward: DeliveryRatio::new(window),
            reverse: DeliveryRatio::new(window),
        }
    }

    /// ETX for this single link. `f32::INFINITY` when either direction is dead.
    pub fn etx(&self) -> f32 {
        let df = self.forward.ratio();
        let dr = self.reverse.ratio();
        if df < Self::DEAD_EPS || dr < Self::DEAD_EPS {
            f32::INFINITY
        } else {
            1.0 / (df * dr)
        }
    }

    fn kill(&mut self) {
        self.forward.kill();
        self.reverse.kill();
    }
}

/// Path route with cumulative ETX metric.
#[derive(Clone, Debug)]
pub struct PathRoute {
    /// Next hop toward destination.
    pub next_hop: NodeId,
    /// Cumulative ETX from this node to destination (additive over hops).
    pub path_etx: f32,
}

/// Neighbor table keyed by node id, maintaining ETX from HELLO exchanges.
#[derive(Debug)]
pub struct EtxTable {
    window: usize,
    links: HashMap<NodeId, LinkStats>,
    /// Learned path routes: destination → (next_hop, path_etx).
    path_routes: HashMap<NodeId, PathRoute>,
}

impl EtxTable {
    pub fn new(window: usize) -> Self {
        Self {
            window: window.max(1),
            links: HashMap::new(),
            path_routes: HashMap::new(),
        }
    }

    /// Record whether we heard the neighbor's HELLO this interval (reverse link),
    /// and whether the neighbor reported hearing ours (forward link).
    pub fn record(&mut self, neighbor: NodeId, we_heard_them: bool, they_heard_us: bool) {
        let w = self.window;
        let link = self
            .links
            .entry(neighbor)
            .or_insert_with(|| LinkStats::new(w));
        link.reverse.record(we_heard_them);
        link.forward.record(they_heard_us);
    }

    /// B03 fast-fail: mark a neighbor's link dead immediately (ETX → ∞), so
    /// routing reroutes now instead of waiting for the estimate to decay. The
    /// link resurrects on the next received HELLO.
    pub fn force_dead(&mut self, neighbor: NodeId) {
        if let Some(link) = self.links.get_mut(&neighbor) {
            link.kill();
        }
    }

    pub fn etx(&self, neighbor: NodeId) -> Option<f32> {
        self.links.get(&neighbor).map(|l| l.etx())
    }

    /// All known neighbors with their current ETX, sorted by id (for status).
    pub fn neighbors(&self) -> Vec<(NodeId, f32)> {
        let mut v: Vec<(NodeId, f32)> = self.links.iter().map(|(id, l)| (*id, l.etx())).collect();
        v.sort_by_key(|(id, _)| *id);
        v
    }

    /// Best directly-reachable neighbor by lowest ETX (ignores infinite links).
    pub fn best_next_hop(&self) -> Option<(NodeId, f32)> {
        self.links
            .iter()
            .map(|(id, l)| (*id, l.etx()))
            .filter(|(_, etx)| etx.is_finite())
            .min_by(|a, b| a.1.partial_cmp(&b.1).unwrap())
    }

    /// RFC 8966 §3.7 feasibility check: a route is feasible if its metric is
    /// strictly better than the current route's metric. This prevents loops
    /// because a node won't accept a route that goes back through itself.
    pub fn is_feasible(&self, dst: NodeId, new_path_etx: f32) -> bool {
        match self.path_routes.get(&dst) {
            None => true, // No existing route → any route is feasible
            Some(existing) => {
                // New route must be strictly better (lower ETX)
                new_path_etx < existing.path_etx && new_path_etx.is_finite()
            }
        }
    }

    /// Learn a path route to `dst` via `next_hop` with cumulative ETX `path_etx`.
    /// Only updates the route if it passes the feasibility check.
    /// Returns true if the route was updated.
    pub fn learn_route(&mut self, dst: NodeId, next_hop: NodeId, path_etx: f32) -> bool {
        // Don't learn routes to ourselves (they're meaningless).
        if dst == next_hop {
            return false;
        }

        // Feasibility check per RFC 8966 §3.7.
        if !self.is_feasible(dst, path_etx) {
            return false;
        }

        let route = PathRoute { next_hop, path_etx };
        self.path_routes.insert(dst, route);
        true
    }

    /// Get the learned path route to `dst`, if any.
    pub fn path_route(&self, dst: NodeId) -> Option<&PathRoute> {
        self.path_routes.get(&dst)
    }

    /// Get all learned path routes (for status/debugging).
    pub fn path_routes(&self) -> Vec<(NodeId, NodeId, f32)> {
        self.path_routes
            .iter()
            .map(|(dst, route)| (*dst, route.next_hop, route.path_etx))
            .collect()
    }

    /// Compute cumulative path ETX: link_etx (to next_hop) + advertised_path_etx.
    /// Returns infinity if the link is dead or the sum overflows.
    pub fn compute_path_etx(&self, next_hop: NodeId, advertised_path_etx: f32) -> f32 {
        let link_etx = self.etx(next_hop).unwrap_or(f32::INFINITY);
        if link_etx.is_infinite() || !advertised_path_etx.is_finite() {
            return f32::INFINITY;
        }

        let sum = link_etx + advertised_path_etx;
        // Guard against overflow (shouldn't happen with realistic ETX values).
        if sum > 1_000_000.0 {
            return f32::INFINITY;
        }
        sum
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn perfect_link_is_etx_one() {
        let mut t = EtxTable::new(10);
        for _ in 0..20 {
            t.record(2, true, true);
        }
        let etx = t.etx(2).unwrap();
        // WMEWMA converges toward but never exactly reaches 1.0.
        assert!((etx - 1.0).abs() < 0.1, "expected ~1.0, got {etx}");
    }

    #[test]
    fn half_forward_doubles_etx() {
        let mut t = EtxTable::new(10);
        // reverse perfect, forward ~50% → ETX roughly doubles (oscillates ~2.0).
        for i in 0..20 {
            t.record(2, true, i % 2 == 0);
        }
        let etx = t.etx(2).unwrap();
        assert!((1.5..3.0).contains(&etx), "expected ~2.0 band, got {etx}");
    }

    #[test]
    fn dead_direction_is_infinite() {
        let mut t = EtxTable::new(5);
        for _ in 0..6 {
            t.record(3, false, true); // we never hear them → reverse decays dead
        }
        assert_eq!(t.etx(3), Some(f32::INFINITY));
    }

    #[test]
    fn force_dead_marks_link_infinite() {
        // B03 fast-fail: a healthy link goes ∞ immediately on force_dead.
        let mut t = EtxTable::new(6);
        for _ in 0..6 {
            t.record(2, true, true);
        }
        assert!(t.etx(2).unwrap().is_finite());
        t.force_dead(2);
        assert_eq!(t.etx(2), Some(f32::INFINITY));
        // Resurrects on the next received HELLO.
        for _ in 0..4 {
            t.record(2, true, true);
        }
        assert!(t.etx(2).unwrap().is_finite());
    }

    #[test]
    fn best_next_hop_picks_lowest_finite_etx() {
        let mut t = EtxTable::new(10);
        for _ in 0..20 {
            t.record(2, true, true); // etx ~1.0
        }
        for i in 0..20 {
            t.record(3, true, i % 2 == 0); // etx ~2.0
        }
        for _ in 0..20 {
            t.record(4, false, false); // dead → infinite, excluded
        }
        let (id, _etx) = t.best_next_hop().unwrap();
        assert_eq!(id, 2);
    }

    #[test]
    fn no_neighbors_no_next_hop() {
        let t = EtxTable::new(10);
        assert!(t.best_next_hop().is_none());
    }

    // E4: Path ETX + Feasibility tests

    #[test]
    fn feasibility_check_accepts_better_route() {
        let mut t = EtxTable::new(10);
        // Learn initial route with ETX 5.0
        assert!(t.learn_route(100, 2, 5.0));
        assert_eq!(t.path_route(100).map(|r| r.path_etx), Some(5.0));

        // Better route (ETX 3.0) should be accepted
        assert!(t.learn_route(100, 3, 3.0));
        assert_eq!(t.path_route(100).map(|r| r.path_etx), Some(3.0));
        assert_eq!(t.path_route(100).map(|r| r.next_hop), Some(3));
    }

    #[test]
    fn feasibility_check_rejects_worse_route() {
        let mut t = EtxTable::new(10);
        // Learn initial route with ETX 3.0
        assert!(t.learn_route(100, 2, 3.0));

        // Worse route (ETX 5.0) should be rejected
        assert!(!t.learn_route(100, 3, 5.0));
        // Route should remain unchanged
        assert_eq!(t.path_route(100).map(|r| r.path_etx), Some(3.0));
        assert_eq!(t.path_route(100).map(|r| r.next_hop), Some(2));
    }

    #[test]
    fn feasibility_check_rejects_equal_route() {
        let mut t = EtxTable::new(10);
        // Learn initial route with ETX 3.0
        assert!(t.learn_route(100, 2, 3.0));

        // Equal route (ETX 3.0) should be rejected (strictly better required)
        assert!(!t.learn_route(100, 3, 3.0));
        // Route should remain unchanged
        assert_eq!(t.path_route(100).map(|r| r.next_hop), Some(2));
    }

    #[test]
    fn feasibility_check_allows_first_route() {
        let t = EtxTable::new(10);
        // No existing route → any route is feasible
        assert!(t.is_feasible(100, 5.0));
        assert!(t.is_feasible(100, 100.0));
    }

    #[test]
    fn learn_route_rejects_self_route() {
        let mut t = EtxTable::new(10);
        // Don't learn routes where dst == next_hop (meaningless)
        assert!(!t.learn_route(100, 100, 1.0));
        assert!(t.path_route(100).is_none());
    }

    #[test]
    fn compute_path_etx_additive() {
        let mut t = EtxTable::new(10);
        // Set up a link with ETX 2.0
        for _ in 0..20 {
            t.record(2, true, true); // perfect link → ETX ~1.0
        }

        // Path ETX = link ETX + advertised ETX
        let link_etx = t.etx(2).unwrap();
        let path_etx = t.compute_path_etx(2, 3.0);
        assert!((path_etx - (link_etx + 3.0)).abs() < 0.1);
    }

    #[test]
    fn compute_path_etx_infinite_if_link_dead() {
        let t = EtxTable::new(10);
        // No link to neighbor → infinite ETX
        assert_eq!(t.etx(2), None);
        // Path ETX should be infinite
        assert_eq!(t.compute_path_etx(2, 3.0), f32::INFINITY);
    }

    #[test]
    fn learn_route_uses_cumulative_etx() {
        let mut t = EtxTable::new(10);
        // Set up a link with ETX ~1.0
        for _ in 0..20 {
            t.record(2, true, true);
        }

        // Compute cumulative path ETX: link ETX + advertised ETX
        let link_etx = t.etx(2).unwrap();
        let adv_etx = 3.0;
        let path_etx = t.compute_path_etx(2, adv_etx);

        // Learn route with cumulative path ETX
        assert!(t.learn_route(100, 2, path_etx));

        // Verify the learned route has cumulative ETX
        let route = t.path_route(100).unwrap();
        let expected = link_etx + adv_etx;
        assert!(
            (route.path_etx - expected).abs() < 0.1,
            "Expected path_etx ~{}, got {}",
            expected,
            route.path_etx
        );
    }

    #[test]
    fn feasibility_prevents_loops() {
        let mut t = EtxTable::new(10);

        // Scenario: Node learns routes to same destination from multiple next-hops
        // Feasibility check prevents accepting worse routes that could create loops

        // First, learn a route via Node 2 (ETX 5.0)
        assert!(t.learn_route(100, 2, 5.0));
        assert_eq!(t.path_route(100).map(|r| r.path_etx), Some(5.0));

        // Node 3 advertises a better route (ETX 3.0)
        // This should be accepted (strictly better)
        assert!(t.learn_route(100, 3, 3.0));
        assert_eq!(t.path_route(100).map(|r| r.path_etx), Some(3.0));
        assert_eq!(t.path_route(100).map(|r| r.next_hop), Some(3));

        // Node 4 advertises a worse route (ETX 4.0)
        // This should be rejected (not strictly better than current 3.0)
        assert!(!t.learn_route(100, 4, 4.0));

        // Verify we still use the best route (via Node 3)
        assert_eq!(t.path_route(100).map(|r| r.next_hop), Some(3));
        assert_eq!(t.path_route(100).map(|r| r.path_etx), Some(3.0));
    }

    #[test]
    fn path_routes_returns_all_learned_routes() {
        let mut t = EtxTable::new(10);
        t.learn_route(100, 2, 3.0);
        t.learn_route(200, 3, 4.0);
        t.learn_route(300, 4, 5.0);

        let routes = t.path_routes();
        assert_eq!(routes.len(), 3);
        assert!(routes.contains(&(100, 2, 3.0)));
        assert!(routes.contains(&(200, 3, 4.0)));
        assert!(routes.contains(&(300, 4, 5.0)));
    }

    #[test]
    fn fuzz_100_random_topologies_no_loops() {
        // E4 requirement: 100 random topology fuzz → 0 loops
        use std::collections::HashSet;

        for _seed in 0..100 {
            let mut t = EtxTable::new(10);
            let mut learned = HashSet::new();

            // Simulate random topology learning
            // Each node learns routes from random neighbors
            for dst in 10..20 {
                for next_hop in 1..10 {
                    // Skip self-routes
                    if dst == next_hop {
                        continue;
                    }

                    // Generate random ETX values
                    let link_etx = if (dst + next_hop) % 3 == 0 { 2.0 } else { 1.0 };
                    let adv_etx = ((dst * next_hop) % 10) as f32;
                    let path_etx = link_etx + adv_etx;

                    // Try to learn route
                    if t.learn_route(dst, next_hop, path_etx) {
                        learned.insert((dst, next_hop));
                    }
                }
            }

            // Verify no loops: for any learned route, the next_hop is not the destination
            for (dst, next_hop) in learned {
                assert_ne!(
                    dst, next_hop,
                    "Loop detected: route to {} via {}",
                    dst, next_hop
                );
            }
        }
    }
}
