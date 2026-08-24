//! discovery_beacon_gates -- CI guard for the mesh-membership HELLO beacon (specs/discovery.t27),
//! the liveness layer that establishes who is alive and reachable (and so feeds routing). The beacon
//! is `[src:4][seq:4][ts:8][n:1][heard:n*4][mac:16]`; its layout arithmetic, the parse-side length
//! gate, and the freshness window had no CI twin. Two properties matter for robustness/security: a
//! TRUNCATED beacon must be rejected BEFORE its 16-byte HMAC is read (a short buffer would put the
//! MAC offset past the end -- read garbage / out of bounds), and a STALE beacon must be rejected so a
//! replayed old HELLO cannot revive a node that has gone dark.

const HDR_LEN: usize = 17;
const HEARD_ENTRY_LEN: usize = 4;
const MAC_LEN: usize = 16;
const FRESHNESS_MS: u64 = 600_000; // 10 minutes

fn mac_offset(n: usize) -> usize {
    HDR_LEN + n * HEARD_ENTRY_LEN
}
fn hello_len(n: usize) -> usize {
    mac_offset(n) + MAC_LEN
}
fn parse_len_ok(byte_len: usize, n: usize) -> bool {
    byte_len >= hello_len(n)
}
fn is_fresh(now_ms: u64, ts_ms: u64) -> bool {
    // symmetric window: clocks drift both ways. abs_diff == the spec's if/else magnitude.
    now_ms.abs_diff(ts_ms) <= FRESHNESS_MS
}

#[test]
fn the_beacon_layout_arithmetic_is_exact() {
    assert_eq!(hello_len(0), 33, "empty beacon = 17 header + 16 MAC");
    assert_eq!(hello_len(3), 45, "3 neighbors = 17 + 12 + 16");
    assert_eq!(mac_offset(3), 29, "MAC after header + 3 heard entries");
    // The MAC always sits exactly MAC_LEN before the end, for any neighbor count.
    for n in 0..64usize {
        assert_eq!(
            hello_len(n) - mac_offset(n),
            MAC_LEN,
            "MAC is the last 16 bytes"
        );
        assert_eq!(
            mac_offset(n),
            HDR_LEN + n * HEARD_ENTRY_LEN,
            "MAC offset is header + n entries"
        );
    }
}

#[test]
fn a_truncated_beacon_is_rejected_before_its_mac_is_read() {
    // The parse gate: a buffer must hold the header, all n heard entries, AND the full MAC.
    assert!(parse_len_ok(45, 3), "an exact-length beacon parses");
    assert!(
        parse_len_ok(46, 3),
        "a longer buffer is fine (trailing bytes)"
    );
    assert!(
        !parse_len_ok(44, 3),
        "one byte short of the MAC end is rejected"
    );
    assert!(
        !parse_len_ok(16, 0),
        "a buffer smaller than even the header is rejected"
    );
    // Sweep: any buffer shorter than hello_len(n) is rejected; anything >= is accepted. So a
    // truncated beacon never reaches the MAC verify at an offset past the buffer end.
    for n in 0..16usize {
        let need = hello_len(n);
        assert!(!parse_len_ok(need - 1, n), "n={n}: one short is rejected");
        assert!(parse_len_ok(need, n), "n={n}: exact length is accepted");
        assert!(
            !parse_len_ok(mac_offset(n), n),
            "n={n}: header+entries but no MAC is rejected"
        );
    }
}

#[test]
fn a_fresh_beacon_is_accepted_in_both_clock_directions() {
    assert!(
        is_fresh(1_000_000, 500_000),
        "a beacon 500s in the past is fresh"
    );
    assert!(
        is_fresh(500_000, 1_000_000),
        "a beacon 500s in the future is fresh (clock drift)"
    );
    assert!(is_fresh(1_000_000, 1_000_000), "same instant is fresh");
}

#[test]
fn a_stale_beacon_cannot_revive_a_dark_node() {
    // Beyond the window in either direction is rejected, so a replayed old HELLO does not keep a
    // node that went dark looking alive.
    assert!(
        !is_fresh(1_000_000, 300_000),
        "700s in the past is stale -> rejected"
    );
    assert!(
        !is_fresh(300_000, 1_000_000),
        "700s in the future is stale -> rejected"
    );
    // The boundary is inclusive at exactly FRESHNESS_MS, exclusive one past it.
    assert!(
        is_fresh(FRESHNESS_MS, 0),
        "exactly at the window edge is still fresh"
    );
    assert!(
        !is_fresh(FRESHNESS_MS + 1, 0),
        "one ms past the window is stale"
    );
}
