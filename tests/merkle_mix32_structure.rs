//! merkle_mix32_structure -- CI guard for the tri_merkle settlement-commitment tree (specs/
//! tri_merkle.t27), the last mix32 gap in docs/CI_GUARD_MAP.md. The hash is the non-cryptographic
//! mix32 (a production commitment would use a real hash -- gft_receipt_batch already guards that with
//! sha2), but the STRUCTURE the spec claims -- order-sensitive parents, tamper-evident roots, and a
//! sound depth-3 inclusion proof that rejects a forged leaf or a wrong sibling -- must hold. This
//! transcribes the tree and pins those structural properties.

const M_C: u32 = 0x9E37_79B9;

fn rotl(x: u32, k: u32) -> u32 {
    x.rotate_left(k)
}
fn mix32(x: u32) -> u32 {
    let a = x ^ (x >> 16);
    let b = a.wrapping_add(a << 3);
    let c = b ^ (b >> 11);
    let d = c.wrapping_add(c << 15);
    d ^ (d >> 16)
}
/// Order-sensitive parent hash: hpair(l,r) != hpair(r,l), so a leaf's left/right position is bound.
fn hpair(l: u32, r: u32) -> u32 {
    let a = mix32(l ^ M_C);
    let b = mix32(r ^ rotl(l, 13));
    mix32(a ^ rotl(b, 7))
}
fn leaf_hash(node_id: u32, total_bytes: u32, quality: u32, reward: u32) -> u32 {
    let a = mix32(node_id ^ rotl(total_bytes, 5));
    let b = mix32(quality ^ rotl(reward, 11));
    hpair(a, b)
}
fn account_leaf(node_id: u32, balance: u32) -> u32 {
    hpair(mix32(node_id ^ M_C), mix32(balance ^ rotl(node_id, 7)))
}
#[allow(clippy::too_many_arguments)]
fn merkle_root8(l0: u32, l1: u32, l2: u32, l3: u32, l4: u32, l5: u32, l6: u32, l7: u32) -> u32 {
    let p0 = hpair(l0, l1);
    let p1 = hpair(l2, l3);
    let p2 = hpair(l4, l5);
    let p3 = hpair(l6, l7);
    hpair(hpair(p0, p1), hpair(p2, p3))
}
fn merkle_step(node: u32, sibling: u32, is_right: u32) -> u32 {
    if is_right == 1 {
        hpair(sibling, node)
    } else {
        hpair(node, sibling)
    }
}
fn merkle_verify8(leaf: u32, s0: u32, s1: u32, s2: u32, idx: u32, root: u32) -> bool {
    let n0 = merkle_step(leaf, s0, idx & 1);
    let n1 = merkle_step(n0, s1, (idx >> 1) & 1);
    let n2 = merkle_step(n1, s2, (idx >> 2) & 1);
    n2 == root
}

fn sample_leaves() -> [u32; 8] {
    [
        leaf_hash(0, 1000, 31, 700),
        leaf_hash(1, 2000, 15, 250),
        leaf_hash(2, 3000, 3, 30),
        leaf_hash(3, 4000, 20, 400),
        leaf_hash(4, 500, 10, 100),
        leaf_hash(5, 600, 5, 60),
        leaf_hash(6, 700, 8, 80),
        leaf_hash(7, 800, 12, 120),
    ]
}
fn root_of(l: &[u32; 8]) -> u32 {
    merkle_root8(l[0], l[1], l[2], l[3], l[4], l[5], l[6], l[7])
}

#[test]
fn parents_are_order_sensitive_so_position_is_bound_into_the_root() {
    assert_ne!(
        hpair(0x1111_1111, 0x2222_2222),
        hpair(0x2222_2222, 0x1111_1111),
        "hpair order matters"
    );
}

#[test]
fn a_correct_inclusion_proof_verifies_at_several_indices() {
    let l = sample_leaves();
    let root = root_of(&l);
    // idx 3: siblings s0=l2, s1=hpair(l0,l1), s2=hpair(hpair(l4,l5),hpair(l6,l7)).
    assert!(
        merkle_verify8(
            l[3],
            l[2],
            hpair(l[0], l[1]),
            hpair(hpair(l[4], l[5]), hpair(l[6], l[7])),
            3,
            root
        ),
        "valid proof for leaf 3"
    );
    // idx 5: s0=l4, s1=hpair(l6,l7), s2=hpair(hpair(l0,l1),hpair(l2,l3)).
    assert!(
        merkle_verify8(
            l[5],
            l[4],
            hpair(l[6], l[7]),
            hpair(hpair(l[0], l[1]), hpair(l[2], l[3])),
            5,
            root
        ),
        "valid proof for leaf 5 (different left/right pattern)"
    );
}

#[test]
fn a_forged_leaf_or_wrong_sibling_does_not_verify() {
    let l = sample_leaves();
    let root = root_of(&l);
    let s1 = hpair(l[0], l[1]);
    let s2 = hpair(hpair(l[4], l[5]), hpair(l[6], l[7]));
    // A node claims a bigger reward (9999 instead of 400) at leaf 3 -> the forged leaf fails.
    let forged = leaf_hash(3, 4000, 20, 9999);
    assert!(
        !merkle_verify8(forged, l[2], s1, s2, 3, root),
        "forged reward rejected"
    );
    // A wrong sibling (l7 instead of l2) cannot fabricate inclusion.
    assert!(
        !merkle_verify8(l[3], l[7], s1, s2, 3, root),
        "wrong sibling s0 rejected"
    );
}

#[test]
fn changing_any_leaf_changes_the_root() {
    let base = merkle_root8(1, 2, 3, 4, 5, 6, 7, 8);
    assert_ne!(
        base,
        merkle_root8(1, 2, 3, 4, 5, 6, 7, 9),
        "a changed last leaf changes the root"
    );
    assert_ne!(
        base,
        merkle_root8(1, 2, 99, 4, 5, 6, 7, 8),
        "a changed middle leaf changes the root"
    );
}

#[test]
fn a_node_proves_its_own_balance_and_cannot_forge_a_fatter_one() {
    let a: [u32; 8] = [
        account_leaf(0, 2108),
        account_leaf(1, 971),
        account_leaf(2, 350),
        account_leaf(3, 1500),
        account_leaf(4, 88),
        account_leaf(5, 640),
        account_leaf(6, 12),
        account_leaf(7, 4096),
    ];
    let state_root = root_of(&a);
    let s1 = hpair(a[2], a[3]);
    let s2 = hpair(hpair(a[4], a[5]), hpair(a[6], a[7]));
    assert!(
        merkle_verify8(a[0], a[1], s1, s2, 0, state_root),
        "node 0 proves balance 2108"
    );
    let forged = account_leaf(0, 999_999);
    assert!(
        !merkle_verify8(forged, a[1], s1, s2, 0, state_root),
        "a forged fatter balance is rejected"
    );
}
