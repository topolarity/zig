comptime {
    var val: u8 = 15;
    var opt_ptr: ?*const u8 = &val;

    const payload_ptr = &opt_ptr.?;
    opt_ptr = null;
    _ = payload_ptr.*;
}

// error
// backend=stage2
// target=native
//
// :7:20: error: unable to unwrap null
