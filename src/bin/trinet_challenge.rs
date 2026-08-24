//! trinet_challenge -- optimistic verification: post a bond, submit a receipt, and
//! let a CHALLENGER recompute it. If the claimed GF-T result does not recompute, the
//! executor's bond is slashed and the challenger is rewarded; if it does, the bond
//! is released. Composes tri_compute_bond + tri_compute_challenge with the real GF-T
//! recompute (tri_gft_arith.gft_mul_result). This scales better than recomputing
//! every receipt (Keryx OPoI / Truebit style): honest work is cheap, fraud is caught.
#![allow(dead_code, unused)]

#[path = "../../gen/rust/tri_gft_arith.rs"]
mod gfa;
#[path = "../../gen/rust/tri_compute_bond.rs"]
mod bond;
#[path = "../../gen/rust/tri_compute_challenge.rs"]
mod ch;

fn run(label: &str, claimed: u32, ex_bal0: u32, bond_amt: u32, ch_bal0: u32, oa: u32, ma: u32, ob: u32, mb: u32) {
    // Executor posts a bond.
    assert!(bond::can_post(ex_bal0, bond_amt), "executor can post the bond");
    let ex_locked = bond::balance_after_post(ex_bal0, bond_amt); // balance minus the locked bond

    // Challenger recomputes the claimed GF-T multiply result from the operands.
    let recomputed = gfa::gft_mul_result(oa, ma, ob, mb, gfa::GFT16_BIAS, gfa::GFT16_OFFSET_MAX);
    let outcome = ch::resolve(claimed, recomputed);

    // Apply the economics.
    let ex_bond_after = ch::executor_bond_after(bond_amt, outcome);
    let ex_bal_after = bond::balance_after_resolve(ex_locked, bond_amt, outcome);
    let ch_reward = ch::challenger_reward(bond_amt, outcome);
    let ch_bal_after = ch_bal0 + ch_reward;
    let state = bond::bond_state_after(outcome);

    let verdict = if outcome == ch::RESOLVE_SLASH { "SLASH " } else { "HONEST" };
    println!("  [{}] claimed={} recomputed={} -> {} | executor bal {}->{} (bond {}->{}) challenger +{} state={}",
        label, claimed, recomputed, verdict, ex_bal0, ex_bal_after, bond_amt, ex_bond_after, ch_reward, state);

    if label == "honest" {
        assert_eq!(outcome, ch::RESOLVE_HONEST);
        assert_eq!(ex_bal_after, ex_bal0, "bond returned -> executor whole");
        assert_eq!(ch_reward, 0, "challenger gains nothing for a false challenge");
        assert_eq!(state, bond::ST_RELEASED);
    } else {
        assert_eq!(outcome, ch::RESOLVE_SLASH);
        assert_eq!(ex_bond_after, 0, "bond slashed");
        assert_eq!(ex_bal_after, ex_locked, "executor loses the bond (not returned)");
        assert_eq!(ch_reward, bond_amt, "challenger rewarded the slashed bond");
        assert_eq!(state, bond::ST_SLASHED);
    }
}

fn main() {
    // GF-T16 mul phi^1 * phi^1 = phi^2: honest result recomputes to encode(42,0).
    let honest = gfa::gft_mul_result(41, 0, 41, 0, gfa::GFT16_BIAS, gfa::GFT16_OFFSET_MAX);
    let fraud = gfa::gft_result_encode(43, 0); // executor claims a wrong exponent (43 not 42)

    println!("optimistic verification (bond + challenge + GF-T recompute):");
    run("honest", honest, 1000, 100, 500, 41, 0, 41, 0);
    run("fraud", fraud, 1000, 100, 500, 41, 0, 41, 0);
    println!("OK: a receipt is accepted optimistically; a challenger who recomputes slashes a fraudulent one and is paid its bond");
}
