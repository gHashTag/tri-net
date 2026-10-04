# Mesh TTL boolean forwarding repair

The source is specs/mesh_protocol_stack.t27. The existing compiler pin
is eb8b4208168557b36dca3a771f6901a5b10d9ef0; it remains unchanged.
The pinned Rust emitter turns a bare tuple-destructured boolean guard into
an invalid comparison with zero. Explicit `expired == true` in the source
preserves the forwarding decision and generates Rust that compiles.

TTL occupies bits 12 through 15. Forwarding decrements a positive TTL once
and expires at zero, including the first hop of a packet starting at one.
Exhausted packets have no next hop. Source, destination, payload and reserved
bits retain their values. All ten function signatures and five constants,
the packet layout and the existing static A/B/C routes are unchanged.

Two new source tests execute the zero/one expiry boundary and preservation
of nonzero reserved bits. All fifteen previous source tests remain.
Generated C, Zig and simulated Verilog each execute all seventeen tests.
Cargo explicitly registers the new Rust target because automatic test
discovery is disabled. Its independent bitmask and routing oracle checks
307,200 TTL/payload/source/destination/current-node combinations and 304
repeated-hop cases against the generated Rust functions.

Validation completed:

- Rust1.96 with denied warnings executes both reference tests successfully.
- Full Cargo suite:435 passed,0 failed,0 ignored across86 targets.
- Formatting, Clippy with denied warnings and the release build pass.
- All284 existing artifacts reproduce:102 Rust,107 Zig and75 C.
- All113 root specifications execute under native Icarus with all four
  cycle budgets unchanged.
- All113 root specifications parse and typecheck within unchanged warning caps.
- Three actual source mutations regenerate and compile, then fail the Rust
  reference tests: removing the expiry guard, retaining a TTL-one packet and
  clearing the reserved bits. The unchanged control passes.

C checks retain the existing unused route parameter and double-parentheses
formatting allowances; no arithmetic or boolean warning is suppressed.
Rust allows existing generated dead code, unused parameters and parentheses;
no boolean type error, unused comparison or unused assignment is allowed.

This is a software forwarding contract. Physical radio transport remains
unverified. The other modules in issue399 require separate repairs.

Closes #403. Refs #399.
