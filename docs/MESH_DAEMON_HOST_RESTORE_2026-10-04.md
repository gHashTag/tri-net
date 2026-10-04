# Mesh daemon imports restored

Closes #393. Refs #96.

Declaring the existing `trios_meshd` target reproduced 13 compiler errors. Its
crate-root imports selected placeholder types rather than the existing crypto,
discovery, router and daemon implementations. Qualified imports restore the
intended `StaticKey`, `Hello`, `Delivery`, `MeshRouter` and `Transport` APIs.
`NodeId` and the component implementations retain their previous definitions.

Cargo explicitly selects the restored binary and the CI known-dead list shrinks
by one. No specification, generated output, protocol constant, crypto algorithm
or Cargo lockfile changed. Existing comment/log punctuation becomes ASCII.

The actual host binary passed a three-process localhost UDP relay: node241 sent
to node243 through node242, and node243 sent back through node242. Both endpoints
logged the exact delivered payloads and the middle process logged both relays.
Dynamic loopback ports and cleared external gateway/fetch environment flags kept
the check local. The shared failure file was not modified and all test processes
were terminated after the result.

This is a demo-key host transport check. It does not prove physical radio,
hardware throughput or a deployed mesh. Parent #96 still includes the excluded
RTI target and remains open.

Final validation on Rust 1.96.0: format, Clippy all targets with `-D warnings`,
normal/release builds and full Cargo tests pass: 432 passed, zero failed or
ignored. This includes the video target restored by PR392.
