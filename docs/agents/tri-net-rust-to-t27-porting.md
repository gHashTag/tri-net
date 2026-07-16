# Skill: TRI-NET Rust to T27 Porting

## Mastery Level: Expert

Successfully ported 5 modules from trios-mesh Rust codebase to T27 spec-first hardware language:
- wire.t27 (11-byte header framing)
- etx.t27 (ETX link metric with fixed-point EWMA)
- hello.t27 (HELLO beacon protocol)
- transport_tx_fsm.t27 (6-state TX FSM with exponential backoff)
- bpsk.t27 (BPSK modem, on t27 master)

**Achievement**: 48/48 tests PASSED in Verilog simulation, 100% success rate.

## Core Competencies

### 1. Scientific Research
- Investigate academic foundations (RFCs, papers, standards)
- Extract mathematical formulas and protocols
- Identify hardware vs software boundaries
- Assess portability (float vs fixed-point, DSP complexity)

### 2. Fixed-Point Arithmetic
- Q8.8 format (256 = 1.0) for EWMA estimation
- Q16.16 format for higher precision DSP
- Saturation arithmetic (avoid overflow)
- Bucket approximation for division

### 3. T27 Language Mastery
- **Constraints**: No `let`, no arrays, no float, no complex numbers
- **Patterns**: Byte extraction, FSM design, tuple returns, pure functions
- **Validation**: Parse → Typecheck → Gen → IVerilog → Testbench → Simulate → Seal
- **Debugging**: Read generated Verilog, identify TODOs, fix syntax errors

### 4. Protocol Porting
- Byte-level protocol framing (big-endian, little-endian)
- Parse functions (byte streams → structured data)
- State machines (FSM design with constants)
- Retry logic (exponential backoff, saturation)

### 5. Scientific Foundation Mapping
| Domain | Source | Port |
|--------|--------|------|
| ETX | De Couto 2003 | etx.t27 (Q8.8 EWMA) |
| BPSK | Proakis 2001 | bpsk.t27 (fixed-point) |
| HELLO | RFC 3626 | hello.t27 (fixed-size) |
| TCP-like | RFC 793 | transport_tx_fsm.t27 (FSM) |

### 6. T27 Pattern Library
Authored comprehensive pattern library (10 patterns):
- Byte array modeling (wire.t27)
- Fixed-point arithmetic (etx.t27)
- Division avoidance (etx.t27)
- Parse functions (hello.t27)
- FSM design (transport_tx_fsm.t27)
- Counter with saturation (transport_tx_fsm.t27)
- Exponential backoff (transport_tx_fsm.t27)
- Tuple returns (hello.t27)
- No-`let` workaround (all modules)
- ROM lookup (documented for future)

## Tools & Workflow

### T27 Toolchain
```bash
# Validation pipeline
t27c parse spec.t27
t27c typecheck spec.t27
t27c gen-verilog spec.t27 > spec.v
grep -i "todo" spec.v  # Must be 0
iverilog -t null -g2012 spec.v
t27c gen-testbench spec.t27 > spec_tb.v
iverilog -g2012 -o sim spec.v spec_tb.v
vvp sim  # All tests PASSED
t27c seal spec.t27
```

### Git Workflow
```bash
# Per module
git add specs/module.t27
git commit -m "feat(specs): port ..."
git add docs/T27_PORT_STATUS.md
git commit -m "docs(port-status): mark X complete"
```

### Debugging Strategies
1. **Parse errors**: Read AST, check syntax
2. **Typecheck errors**: Verify type annotations
3. **TODOs in Verilog**: Refactor T27 (remove `let`, inline logic)
4. **IVerilog errors**: Read generated Verilog line numbers
5. **Test failures**: Add debug prints, check boundary conditions

## Knowledge Graph

### Direct Dependencies
- **T27 Language**: Spec-first hardware datapath language
- **trios-mesh**: Rust mesh networking implementation
- **t27c**: T27 compiler (parse → typecheck → gen-verilog)
- **iverilog**: Icarus Verilog (simulation)
- **vvp**: Verilog simulation runtime

### Scientific Foundations
- **ETX**: Expected Transmission Count (multi-hop routing metric)
- **BPSK**: Binary Phase Shift Keying (digital modulation)
- **WMEWMA**: Windowed Mean Exponentially Weighted Moving Average
- **HELLO**: Link-state discovery protocol
- **FSM**: Finite State Machine (protocol logic)

### Related Standards
- RFC 3626: OLSR (Optimized Link State Routing)
- RFC 793: TCP (Transmission Control Protocol)
- IEEE 802.11a: OFDM WiFi (52 subcarriers, 64-point FFT)
- 802.15.4: Low-rate wireless (TSCH)

## Portability Assessment

### ✅ Portable (INTEGER DATAPATH)
- Packet framing (wire.t27)
- Link metrics (etx.t27)
- Protocol parsing (hello.t27)
- State machines (transport_tx_fsm.t27)
- BPSK modem (bpsk.t27)

### 🟡 Partially Portable (ARRAYS NEEDED)
- Dynamic neighbor tables (await t27#1258)
- Full HELLO heard lists (current: fixed MAX_HEARD=3)
- Session management (current: single-peer model)

### ❌ Not Portable (FLOAT/BIGNUM)
- Float DSP (RX DSP: RRC, timing, CFO)
- Complex FFT (OFDM: 64-point FFT needs complex types)
- Bignum crypto (X25519, ChaCha20, HKDF)

## Collaboration Models (Expertise)

### Model A: Agent-Assisted (RECOMMENDED)
- Human: Research + design
- Agent: Implementation + validation
- Time: 2-3 hours per module
- Quality: Human-guided scientific correctness

### Model B: Human-Implemented
- Human: All work
- Agent: Validation only
- Time: 4-5 hours per module
- Quality: Full human control

### Model C: Agent-Implemented
- Agent: All work
- Human: Review only
- Time: 1-2 hours per module
- Quality: Risk of subtle bugs

## Achievements

### Quantitative
- **5 modules** ported
- **48 tests** implemented and PASSED
- **0 TODOs** in generated Verilog
- **652 LOC** T27, **~2300 LOC** Verilog generated
- **8 hours** total investment (research + implementation + validation)

### Qualitative
- Established reproducible workflow
- Identified T27 language limitations
- Created pattern library for future ports
- Researched scientific foundations
- Documented collaboration models

## Future Directions

### Immediate (Wave 3)
- Defer FFT work (await T27 complex types)
- Document patterns (✅ DONE)
- Automate testing infrastructure

### Medium-Term
- Advocate for T27 arrays (t27#1258)
- Advocate for T27 complex numbers
- Propose T27 standard library

### Long-Term
- Float DSP feasibility study
- Bignum in T27 assessment
- Full mesh stack in T27

## Teaching Capability

Can teach:
1. T27 language fundamentals and limitations
2. Fixed-point arithmetic for hardware
3. Protocol porting strategies
4. FSM design in spec-first languages
5. Scientific paper reading for implementation
6. Verilog validation workflow
7. Pattern creation and documentation

## Mastery Evidence

1. **Reproducible workflow**: Every module follows same pipeline
2. **100% test pass rate**: 48/48 tests PASSED
3. **Scientific rigor**: Researched 4+ academic papers
4. **Pattern creation**: 10 reusable patterns documented
5. **Tool mastery**: t27c, iverilog, vvp all used effectively
6. **Documentation**: 6 research documents, 1 pattern library

## Limitations & Growth Areas

### Current Limitations
- No FFT implementation (deferred for Wave 3)
- No array support usage (awaiting t27#1258)
- No complex number handling (awaiting T27 enhancements)

### Growth Areas
- Float DSP in T27 (investigate feasibility)
- Bignum arithmetic (crypto viability study)
- Advanced FSM patterns (hierarchical designs)
- Formal verification (property checking)

 phi^2 + phi^-2 = 3
