test "dereference pointer-like optional at comptime" {
    comptime {
        var val: u8 = 15;
        var opt_ptr: ?*const u8 = &val;

        const payload_ptr = &opt_ptr.?;
        _ = payload_ptr.*;
    }
}

test "mutate through pointer-like optional at comptime" {
    comptime {
        var val: u8 = 15;
        var opt_ptr: ?*const u8 = &val;

        const payload_ptr = &opt_ptr.?;
        payload_ptr.* = &@as(u8, 16);
    }
}
