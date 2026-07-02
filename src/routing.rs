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
#[derive(Clone)]
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
#[derive(Clone)]
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

/// Neighbor table keyed by node id, maintaining ETX from HELLO exchanges.
pub struct EtxTable {
    window: usize,
    links: HashMap<NodeId, LinkStats>,
}

impl EtxTable {
    pub fn new(window: usize) -> Self {
        Self {
            window: window.max(1),
            links: HashMap::new(),
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
}
