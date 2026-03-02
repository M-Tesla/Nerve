//! PIX transaction state machine for SPI.
//! Pure functions — no I/O, no external state, fully testable.

const std = @import("std");
const db_mod = @import("db.zig");

pub const TxState = db_mod.TxState;

pub const TransitionError = error{InvalidTransition};

/// Returns true if the transition from → to is valid in the PIX flow.
pub fn canTransition(from: TxState, to: TxState) bool {
    return switch (from) {
        .pending  => to == .reserved or to == .failed,
        .reserved => to == .settled or to == .reversed,
        // Terminal states do not transition
        .settled  => false,
        .reversed => false,
        .failed   => false,
    };
}

/// Validate the transition from → to. Returns error.InvalidTransition if invalid.
pub fn validateTransition(from: TxState, to: TxState) TransitionError!void {
    if (!canTransition(from, to)) return TransitionError.InvalidTransition;
}

/// Returns true if the state is terminal (will not transition further).
pub fn isTerminal(state: TxState) bool {
    return switch (state) {
        .settled, .reversed, .failed => true,
        .pending, .reserved          => false,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "valid transitions from PENDING" {
    try validateTransition(.pending, .reserved);
    try validateTransition(.pending, .failed);
}

test "valid transitions from RESERVED" {
    try validateTransition(.reserved, .settled);
    try validateTransition(.reserved, .reversed);
}

test "invalid transition: PENDING → SETTLED" {
    try std.testing.expectError(TransitionError.InvalidTransition,
        validateTransition(.pending, .settled));
}

test "invalid transition: PENDING → REVERSED" {
    try std.testing.expectError(TransitionError.InvalidTransition,
        validateTransition(.pending, .reversed));
}

test "invalid transitions from terminal states" {
    const terminals = [_]TxState{ .settled, .reversed, .failed };
    const all_states = [_]TxState{ .pending, .reserved, .settled, .reversed, .failed };

    for (terminals) |term| {
        for (all_states) |to| {
            try std.testing.expect(!canTransition(term, to));
        }
    }
}

test "terminal states are correct" {
    try std.testing.expect(isTerminal(.settled));
    try std.testing.expect(isTerminal(.reversed));
    try std.testing.expect(isTerminal(.failed));
    try std.testing.expect(!isTerminal(.pending));
    try std.testing.expect(!isTerminal(.reserved));
}

test "RESERVED → SETTLED and REVERSED are mutually exclusive" {
    // Both settled and reversed are valid from reserved
    try std.testing.expect(canTransition(.reserved, .settled));
    try std.testing.expect(canTransition(.reserved, .reversed));
    // But cannot go from settled to reversed or vice versa
    try std.testing.expect(!canTransition(.settled, .reversed));
    try std.testing.expect(!canTransition(.reversed, .settled));
}
