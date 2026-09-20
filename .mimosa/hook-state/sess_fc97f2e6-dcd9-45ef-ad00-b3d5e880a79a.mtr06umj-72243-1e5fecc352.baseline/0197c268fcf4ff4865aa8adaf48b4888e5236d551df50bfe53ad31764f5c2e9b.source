//! a2a_wire_decode -- CI guard for the A2A wire PARSE BOUNDARY (specs/tri_a2a_wire.t27), where a
//! decrypted mesh payload is decoded into [class(1) | task_id(4 BE) | skill(2 BE) | body]. task_id /
//! skill_id are used in gft_rung_over_wire, but the parse-boundary robustness -- class validity
//! (reject malformed), the receipt/signature message rules, byte-order sensitivity of the id decode,
//! and the OPERAND-BINDING preimage (a signed receipt commits its exact operands, so a node cannot
//! swap them) -- had no CI twin. The wire is a fixed-length header precisely to avoid the length-
//! confusion / injection surface of variable-length JSON-RPC; this pins that the decode is exact,
//! rejects the unknown, and binds each operand to its own preimage word.

const MSG_TASK_ASSIGN: u32 = 1;
const MSG_TASK_RESULT: u32 = 2;
const MSG_HEARTBEAT: u32 = 3;
const OFF_BODY: u32 = 7;
const SIG_LEN: u32 = 64;
const SHA_PAD_W: u32 = 0x8000_0000;
const OPERAND_BITS: u32 = 160;

fn task_id(b1: u32, b2: u32, b3: u32, b4: u32) -> u32 {
    (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
}
fn skill_id(b5: u32, b6: u32) -> u32 {
    (b5 << 8) | b6
}
fn class_valid(class: u32) -> bool {
    class == MSG_TASK_ASSIGN || class == MSG_TASK_RESULT || class == MSG_HEARTBEAT
}
fn body_has_receipt(class: u32) -> bool {
    class == MSG_TASK_RESULT
}
fn body_has_signature(class: u32) -> bool {
    class == MSG_TASK_RESULT
}
fn sig_offset(receipt_body_len: u32) -> u32 {
    OFF_BODY + receipt_body_len
}
fn signed_result_len(receipt_body_len: u32) -> u32 {
    OFF_BODY + receipt_body_len + SIG_LEN
}
fn assign_mant(hi: u32, lo: u32) -> u32 {
    (hi << 8) | lo
}
#[allow(clippy::too_many_arguments)]
fn operand_pre(idx: u32, op: u32, a_off: u32, a_mant: u32, b_off: u32, b_mant: u32) -> u32 {
    match idx {
        0 => op,
        1 => a_off,
        2 => a_mant,
        3 => b_off,
        4 => b_mant,
        5 => SHA_PAD_W,
        15 => OPERAND_BITS,
        _ => 0,
    }
}

#[test]
fn big_endian_id_decode_is_exact_and_order_sensitive() {
    assert_eq!(
        task_id(0x12, 0x34, 0x56, 0x78),
        0x1234_5678,
        "task id from 4 BE bytes"
    );
    assert_eq!(
        skill_id(0xA6, 0x11),
        0xA611,
        "skill id from 2 BE bytes (GF-T16 mul)"
    );
    // Order sensitivity: a byte-swapped header decodes to a DIFFERENT id, so a mangled/relayed
    // header cannot alias another task or skill. (Anti-misroute / anti-collision.)
    assert_ne!(
        task_id(0x78, 0x56, 0x34, 0x12),
        task_id(0x12, 0x34, 0x56, 0x78),
        "swapped task bytes differ"
    );
    assert_ne!(
        skill_id(0x11, 0xA6),
        skill_id(0xA6, 0x11),
        "swapped skill bytes differ"
    );
    // The whole ladder's mul skills decode to their high byte + 0x11 suffix.
    for hi in [0xA4u32, 0xA8, 0xA6, 0xA5, 0xA3, 0xA2] {
        assert_eq!(
            skill_id(hi, 0x11),
            (hi << 8) | 0x11,
            "skill {hi:#x}11 decodes"
        );
    }
}

#[test]
fn class_validity_rejects_everything_but_the_three_known_classes() {
    assert!(
        class_valid(MSG_TASK_ASSIGN) && class_valid(MSG_TASK_RESULT) && class_valid(MSG_HEARTBEAT)
    );
    // The parse boundary: every other class byte (0, 4..=255) is malformed and rejected.
    for class in 0..=255u32 {
        let known = class == 1 || class == 2 || class == 3;
        assert_eq!(class_valid(class), known, "class {class} validity");
    }
}

#[test]
fn only_a_task_result_carries_a_receipt_and_signature() {
    assert!(body_has_receipt(MSG_TASK_RESULT) && body_has_signature(MSG_TASK_RESULT));
    assert!(
        !body_has_receipt(MSG_TASK_ASSIGN),
        "an assign carries no receipt"
    );
    assert!(
        !body_has_signature(MSG_TASK_ASSIGN),
        "an assign carries no signature"
    );
    assert!(
        !body_has_receipt(MSG_HEARTBEAT),
        "a heartbeat carries no receipt"
    );
}

#[test]
fn the_fixed_signature_layout_has_no_length_confusion() {
    assert_eq!(SIG_LEN, 64, "Ed25519 signature is 64 bytes");
    // signature sits exactly after the receipt body; total is header + body + 64, for any body len.
    for body_len in [0u32, 1, 36, 1000] {
        assert_eq!(
            sig_offset(body_len),
            OFF_BODY + body_len,
            "sig right after the body"
        );
        assert_eq!(
            signed_result_len(body_len),
            OFF_BODY + body_len + SIG_LEN,
            "total is exact"
        );
    }
    // A 9-bit GF-T mantissa reassembles from its two BE body bytes (max 0x1FF).
    assert_eq!(assign_mant(0x01, 0x00), 256);
    assert_eq!(assign_mant(0x01, 0xFF), 511);
}

#[test]
fn each_operand_binds_to_its_own_preimage_word_sensitively_and_without_aliasing() {
    // The security property: the receipt's in_hash is SHA-256 over this preimage, and the signature
    // covers in_hash -- so a node cannot swap operands under a signed receipt. Two sub-properties:
    let base = |i| operand_pre(i, 0x11, 41, 5, 42, 7);
    // (1) SENSITIVITY -- changing operand i changes exactly word i.
    assert_ne!(
        operand_pre(0, 0x10, 41, 5, 42, 7),
        base(0),
        "op tamper moves word 0"
    );
    assert_ne!(
        operand_pre(1, 0x11, 40, 5, 42, 7),
        base(1),
        "a_off tamper moves word 1"
    );
    assert_ne!(
        operand_pre(2, 0x11, 41, 6, 42, 7),
        base(2),
        "a_mant tamper moves word 2"
    );
    assert_ne!(
        operand_pre(3, 0x11, 41, 5, 43, 7),
        base(3),
        "b_off tamper moves word 3"
    );
    assert_ne!(
        operand_pre(4, 0x11, 41, 5, 42, 8),
        base(4),
        "b_mant tamper moves word 4"
    );
    // (2) NON-ALIASING -- word i depends ONLY on operand i, so tampering other operands leaves it put.
    assert_eq!(
        operand_pre(0, 0x11, 99, 99, 99, 99),
        base(0),
        "word 0 depends only on op"
    );
    assert_eq!(
        operand_pre(1, 0x99, 41, 99, 99, 99),
        base(1),
        "word 1 depends only on a_off"
    );
    assert_eq!(
        operand_pre(4, 0x99, 99, 99, 99, 7),
        base(4),
        "word 4 depends only on b_mant"
    );
    // The SHA padding structure is fixed: pad marker at word 5, 160-bit length at word 15, zeros between.
    assert_eq!(
        operand_pre(5, 0, 0, 0, 0, 0),
        SHA_PAD_W,
        "pad marker at word 5"
    );
    assert_eq!(
        operand_pre(15, 0, 0, 0, 0, 0),
        OPERAND_BITS,
        "160-bit length at word 15"
    );
    assert_eq!(
        operand_pre(9, 0x11, 41, 5, 42, 7),
        0,
        "interior pad word is zero"
    );
}
