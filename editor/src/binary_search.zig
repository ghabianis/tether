
pub const Order = enum {
    Less,
    Equal,
    Greater,
};

pub fn find_index(comptime T: type, arr: []const T, search_elem: *const T, cmp: fn(*const T, *const T) Order) ?usize {
    var size: usize = arr.len;
    var left: usize = 0;
    var right: usize = size;

    while (left < right) {
        const mid = left + size / 2;
        const item: *const T = &arr[mid];
        switch (cmp(search_elem, item)) {
            .Equal => return mid,
            .Less => {
                right = mid;
            },
            .Greater => {
                left = mid + 1;
            },
        }
        size = right - left;
    }

    return null;
}