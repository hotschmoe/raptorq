// Union-find based connected component graph for PI solver Phase 1.
// Allocated once per solve, reset() between iterations (no alloc/dealloc per r=2 step).

const std = @import("std");

pub const ConnectedComponentGraph = struct {
    // Union-find parent array. parent[i] == i means i is a root.
    // Initialized to sentinel (maxInt) meaning "unassigned".
    parent: []u32,
    rank: []u16,
    component_size: []u32,
    max_nodes: u32,
    // Track which nodes are active so reset() only touches used entries
    active_nodes: []u32,
    num_active: u32,

    const UNASSIGNED: u32 = std.math.maxInt(u32);

    pub fn init(allocator: std.mem.Allocator, max_nodes: u32) !ConnectedComponentGraph {
        const parent = try allocator.alloc(u32, max_nodes);
        errdefer allocator.free(parent);
        const rank = try allocator.alloc(u16, max_nodes);
        errdefer allocator.free(rank);
        const comp_size = try allocator.alloc(u32, max_nodes);
        errdefer allocator.free(comp_size);
        const active = try allocator.alloc(u32, max_nodes);
        errdefer allocator.free(active);

        @memset(parent, UNASSIGNED);
        @memset(rank, 0);
        @memset(comp_size, 0);

        return .{
            .parent = parent,
            .rank = rank,
            .component_size = comp_size,
            .max_nodes = max_nodes,
            .active_nodes = active,
            .num_active = 0,
        };
    }

    pub fn deinit(self: *ConnectedComponentGraph, allocator: std.mem.Allocator) void {
        allocator.free(self.parent);
        allocator.free(self.rank);
        allocator.free(self.component_size);
        allocator.free(self.active_nodes);
    }

    pub fn reset(self: *ConnectedComponentGraph) void {
        for (self.active_nodes[0..self.num_active]) |node| {
            self.parent[node] = UNASSIGNED;
            self.rank[node] = 0;
            self.component_size[node] = 0;
        }
        self.num_active = 0;
    }

    fn ensureNode(self: *ConnectedComponentGraph, node: u32) void {
        if (self.parent[node] == UNASSIGNED) {
            self.parent[node] = node;
            self.component_size[node] = 1;
            self.active_nodes[self.num_active] = node;
            self.num_active += 1;
        }
    }

    fn find(self: *ConnectedComponentGraph, node: u32) u32 {
        var x = node;
        while (self.parent[x] != x) {
            // Path splitting: make each node point to its grandparent
            self.parent[x] = self.parent[self.parent[x]];
            x = self.parent[x];
        }
        return x;
    }

    pub fn addEdge(self: *ConnectedComponentGraph, u: u32, v: u32) void {
        self.ensureNode(u);
        self.ensureNode(v);

        const root_u = self.find(u);
        const root_v = self.find(v);
        if (root_u == root_v) return;

        // Union by rank
        const total_size = self.component_size[root_u] + self.component_size[root_v];
        if (self.rank[root_u] < self.rank[root_v]) {
            self.parent[root_u] = root_v;
            self.component_size[root_v] = total_size;
        } else {
            self.parent[root_v] = root_u;
            self.component_size[root_u] = total_size;
            if (self.rank[root_u] == self.rank[root_v]) self.rank[root_u] += 1;
        }
    }

    /// Find a node in [start, end) that belongs to the largest component.
    /// Returns null if no active nodes exist in the range.
    pub fn getNodeInLargestComponent(self: *ConnectedComponentGraph, start: u32, end: u32) ?u32 {
        var best_node: ?u32 = null;
        var best_size: u32 = 0;

        for (self.active_nodes[0..self.num_active]) |node| {
            if (node < start or node >= end) continue;
            const root = self.find(node);
            const sz = self.component_size[root];
            if (sz > best_size) {
                best_size = sz;
                best_node = node;
            }
        }

        return best_node;
    }
};

test "ConnectedComponentGraph single component" {
    var g = try ConnectedComponentGraph.init(std.testing.allocator, 4);
    defer g.deinit(std.testing.allocator);

    g.addEdge(0, 1);
    g.addEdge(1, 2);
    g.addEdge(2, 3);

    // All 4 nodes in one component
    const root = g.find(0);
    try std.testing.expectEqual(g.find(1), root);
    try std.testing.expectEqual(g.find(2), root);
    try std.testing.expectEqual(g.find(3), root);
    try std.testing.expectEqual(@as(u32, 4), g.component_size[root]);
}

test "ConnectedComponentGraph multiple components" {
    var g = try ConnectedComponentGraph.init(std.testing.allocator, 6);
    defer g.deinit(std.testing.allocator);

    g.addEdge(0, 1);
    g.addEdge(2, 3);
    g.addEdge(4, 5);

    try std.testing.expect(g.find(0) != g.find(2));
    try std.testing.expect(g.find(2) != g.find(4));
    try std.testing.expect(g.find(0) != g.find(4));
}

test "ConnectedComponentGraph reset" {
    var g = try ConnectedComponentGraph.init(std.testing.allocator, 4);
    defer g.deinit(std.testing.allocator);

    g.addEdge(0, 1);
    g.addEdge(2, 3);
    try std.testing.expectEqual(@as(u32, 4), g.num_active);

    g.reset();
    try std.testing.expectEqual(@as(u32, 0), g.num_active);
    try std.testing.expectEqual(ConnectedComponentGraph.UNASSIGNED, g.parent[0]);

    // Can reuse after reset
    g.addEdge(0, 3);
    try std.testing.expectEqual(g.find(0), g.find(3));
}

test "ConnectedComponentGraph getNodeInLargestComponent" {
    var g = try ConnectedComponentGraph.init(std.testing.allocator, 10);
    defer g.deinit(std.testing.allocator);

    // Component 1: {2, 5, 7} (size 3)
    g.addEdge(2, 5);
    g.addEdge(5, 7);
    // Component 2: {3, 8} (size 2)
    g.addEdge(3, 8);

    const node = g.getNodeInLargestComponent(0, 10);
    try std.testing.expect(node != null);
    // Should be in the {2, 5, 7} component
    const root = g.find(node.?);
    try std.testing.expectEqual(g.find(2), root);
}

test "ConnectedComponentGraph self-loop" {
    var g = try ConnectedComponentGraph.init(std.testing.allocator, 3);
    defer g.deinit(std.testing.allocator);

    g.addEdge(0, 0);
    g.addEdge(1, 2);

    try std.testing.expect(g.find(0) != g.find(1));
    try std.testing.expectEqual(@as(u32, 1), g.component_size[g.find(0)]);
    try std.testing.expectEqual(@as(u32, 2), g.component_size[g.find(1)]);
}
