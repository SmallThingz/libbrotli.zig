const std = @import("std");

/// Heap-stable callback context; all native allocations use the caller allocator.
pub const Memory = struct {
    allocator: std.mem.Allocator,
    failed: bool = false,

    pub fn create(allocator: std.mem.Allocator) !*Memory {
        const self = try allocator.create(Memory);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *Memory) void {
        self.allocator.destroy(self);
    }

    pub fn alloc(opaque_ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
        const self: *Memory = @ptrCast(@alignCast(opaque_ptr.?));
        const total = std.math.add(usize, size, 16) catch {
            self.failed = true;
            return null;
        };
        const bytes = self.allocator.alignedAlloc(u8, .@"16", total) catch {
            self.failed = true;
            return null;
        };
        const length: *usize = @ptrCast(bytes.ptr);
        length.* = total;
        return bytes.ptr + 16;
    }

    pub fn free(opaque_ptr: ?*anyopaque, address: ?*anyopaque) callconv(.c) void {
        const ptr = address orelse return;
        const self: *Memory = @ptrCast(@alignCast(opaque_ptr.?));
        const base: [*]align(16) u8 = @alignCast(@as([*]u8, @ptrCast(ptr)) - 16);
        const length: *const usize = @ptrCast(base);
        self.allocator.free(base[0..length.*]);
    }
};
