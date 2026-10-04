// Compile and execute the generated module, including its unsigned warnings.
#[allow(dead_code, unused_parens, clippy::all)]
#[path = "../gen/rust/pattern_predictor.rs"]
mod generated;

fn packed(values: [u32; 16]) -> [u32; 16] {
    values.map(|value| generated::create_sample(value, 0, 0, 1))
}

#[test]
fn empty_partial_and_oversized_windows() {
    let values = [2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32];
    let array = packed(values);
    for (window, mean) in [(0, 0), (1, 2), (5, 6), (9, 10), (u32::MAX, 17)] {
        assert_eq!(generated::calculate_moving_average(array, window), mean);
    }
    for (window, variance) in [(0, 0), (1, 0), (5, 8), (16, 85), (u32::MAX, 85)] {
        assert_eq!(generated::calculate_variance(array, window), variance);
    }
    assert_eq!(generated::predict_next_value(array, 0), 0);
    assert_eq!(generated::predict_next_value(array, u32::MAX), 42);
}

#[test]
fn mean_and_variance_match_all_selected_values() {
    for seed in 0u32..256 {
        let values = std::array::from_fn(|i| (seed + i as u32 * 37) % 256);
        let array = packed(values);
        for requested in (0u32..21).chain([u32::MAX]) {
            let count = requested.min(16) as usize;
            // Wide arithmetic and slices form an independent reference.
            let sum: u64 = values[..count].iter().map(|&x| u64::from(x)).sum();
            let mean = if count == 0 { 0 } else { sum / count as u64 };
            let square_sum: u64 = values[..count]
                .iter()
                .map(|&x| (i64::from(x) - mean as i64).unsigned_abs().pow(2))
                .sum();
            let variance = if count < 2 {
                0
            } else {
                square_sum / count as u64
            };
            assert_eq!(
                generated::calculate_moving_average(array, requested),
                mean as u32
            );
            assert_eq!(
                generated::calculate_variance(array, requested),
                variance as u32
            );
        }
    }
}

#[test]
fn all_byte_endpoints_match_signed_trend_and_saturating_prediction() {
    for first in 0u32..256 {
        for last in 0u32..256 {
            let mut values = [0; 16];
            values[0] = first;
            values[1] = last;
            values[15] = last;
            let array = packed(values);
            let delta = i64::from(last) - i64::from(first);
            let trend = if delta > 5 {
                1
            } else if delta < -5 {
                2
            } else {
                0
            };
            let prediction = match trend {
                1 => last + 10,
                2 => last.saturating_sub(10),
                _ => last,
            };
            for samples in [2, 16, u32::MAX] {
                assert_eq!(generated::detect_trend(array, samples), trend);
                assert_eq!(generated::predict_next_value(array, samples), prediction);
            }
            assert_eq!(generated::detect_trend(array, 0), 0);
            assert_eq!(generated::predict_next_value(array, 0), 0);
            assert_eq!(generated::detect_trend(array, 1), 0);
            assert_eq!(generated::predict_next_value(array, 1), first);
        }
    }
}
