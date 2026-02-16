// Connected component tracking for PI solver Phase 1

const std = @import("std");

pub const Graph = struct {
    num_nodes: u32,
    adjacency: []std.ArrayList(u32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_nodes: u32) !Graph {
        const adj = try allocator.alloc(std.ArrayList(u32), num_nodes);
        for (adj) |*list| {
            list.* = .empty;
        }
        return .{
            .num_nodes = num_nodes,
            .adjacency = adj,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Graph) void {
        for (self.adjacency) |*list| {
            list.deinit(self.allocator);
        }
        self.allocator.free(self.adjacency);
    }

    pub fn addEdge(self: *Graph, u: u32, v: u32) !void {
        try self.adjacency[u].append(self.allocator, v);
        if (u != v) {
            try self.adjacency[v].append(self.allocator, u);
        }
    }

    pub fn connectedComponents(self: *Graph, allocator: std.mem.Allocator) ![]u32 {
        const sentinel = std.math.maxInt(u32);
        const labels = try allocator.alloc(u32, self.num_nodes);
        @memset(labels, sentinel);

        var queue: std.ArrayList(u32) = .empty;
        defer queue.deinit(allocator);

        var component_id: u32 = 0;
        var node: u32 = 0;
        while (node < self.num_nodes) : (node += 1) {
            if (labels[node] != sentinel) continue;

            labels[node] = component_id;
            queue.clearRetainingCapacity();
            try queue.append(allocator, node);

            while (queue.items.len > 0) {
                const current = queue.orderedRemove(0);
                for (self.adjacency[current].items) |neighbor| {
                    if (labels[neighbor] == sentinel) {
                        labels[neighbor] = component_id;
                        try queue.append(allocator, neighbor);
                    }
                }
            }

            component_id += 1;
        }

        return labels;
    }

    pub fn numComponents(self: *Graph, allocator: std.mem.Allocator) !u32 {
        const labels = try self.connectedComponents(allocator);
        defer allocator.free(labels);

        if (labels.len == 0) return 0;

        var max_label: u32 = 0;
        for (labels) |l| {
            if (l > max_label) max_label = l;
        }
        return max_label + 1;
    }
};

test "Graph single component" {
    var g = try Graph.init(std.testing.allocator, 4);
    defer g.deinit();

    try g.addEdge(0, 1);
    try g.addEdge(1, 2);
    try g.addEdge(2, 3);

    const nc = try g.numComponents(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), nc);
}

test "Graph multiple components" {
    var g = try Graph.init(std.testing.allocator, 6);
    defer g.deinit();

    try g.addEdge(0, 1);
    try g.addEdge(2, 3);
    try g.addEdge(4, 5);

    const nc = try g.numComponents(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 3), nc);
}

test "Graph connected components labels" {
    var g = try Graph.init(std.testing.allocator, 5);
    defer g.deinit();

    try g.addEdge(0, 1);
    try g.addEdge(3, 4);

    const labels = try g.connectedComponents(std.testing.allocator);
    defer std.testing.allocator.free(labels);

    try std.testing.expectEqual(labels[0], labels[1]);
    try std.testing.expect(labels[0] != labels[2]);
    try std.testing.expect(labels[2] != labels[3]);
    try std.testing.expectEqual(labels[3], labels[4]);
}

test "Graph self-loop" {
    var g = try Graph.init(std.testing.allocator, 3);
    defer g.deinit();

    try g.addEdge(0, 0);
    try g.addEdge(1, 2);

    const nc = try g.numComponents(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), nc);
}
