comptime {
    var err_union: error{Foo, Bar}!u8 = 15;

    const payload_ptr = &(err_union catch unreachable);
    err_union = error.Foo;
    _ = payload_ptr.*;
}

// error
// backend=stage2
// target=native
//
// :6:20: error: unable to unwrap error union
