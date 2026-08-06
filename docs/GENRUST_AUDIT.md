# gen-rust health audit

The compute-receipt / A2A-over-mesh / ternary ring gen-rusts + rustc-compiles clean (0 errors). The t27c bool-!/return-coercion defect (flagged upstream) affects 16 out-of-ring routing/security/telemetry specs, listed for scoping the fix: access_control, adaptive_retry, api_documenter, auto_config, crc16, link_quality_monitor, lite_crypto, m3_multihop, mesh_routing, multipath_router, olsr_routing, pattern_predictor, rti_security, traffic_animator, trust_manager, video_bridge. crypto_frame.t27 carries the spec-side workaround until t27c is fixed.
