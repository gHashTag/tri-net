use trios_mesh::etx::ewma_update;

#[test]
fn ewma_matches_exact_rational_blend_for_every_u8_triple() {
    for alpha in 0..=u8::MAX {
        for est in 0..=u8::MAX {
            for sample in 0..=u8::MAX {
                // An independent wide rational reference: denominator 256,
                // with one final floor. Do not call generated fp_mul here.
                let weight = u64::from(alpha);
                let expected = (weight * u64::from(sample) + (256 - weight) * u64::from(est)) / 256;
                assert_eq!(
                    u64::from(ewma_update(est, sample, alpha)),
                    expected,
                    "est={est}, sample={sample}, alpha={alpha}"
                );
            }
        }
    }
}
