///! Minimal reproduction: httpz blocking-mode server hangs on stop()
///!
///! On Windows (blocking mode), calling server.stop() hangs because:
///!
///! 1. stop() calls posix.shutdown(listener, .recv) — this is a no-op on Windows
///!    for listening sockets (returns WSAENOTCONN, silently caught).
///!
///! 2. stop() calls posix.close(listener) — closes the socket handle.
///!
///! 3. The blocking worker thread is stuck in accept(). On Windows, accept() on
///!    a closed socket returns WSAENOTSOCK → error.FileDescriptorNotASocket.
///!
///! 4. The worker's listen loop only breaks on ConnectionAborted or
///!    SocketNotListening — FileDescriptorNotASocket falls through to `continue`,
///!    creating an infinite error loop that burns 100% of one core.
///!
///! 5. Since the worker thread never exits, thread_pool.stop() never runs,
///!    so all pool threads stay alive too.
///!
///! 6. The listen_thread.join() in the caller hangs forever.
///!
///! Result: REAPER process stays alive after exit, accumulating zombie instances.
///!
///! Run: zig build repro-blocking-shutdown
///! Expected: exits cleanly within a few seconds
///! Actual (before fix): hangs forever, must be killed
const std = @import("std");
const httpz = @import("httpz");

const print = std.debug.print;
const Server = httpz.Server(void);

pub fn main() !void {
    print("=== httpz blocking-mode shutdown repro ===\n", .{});
    print("blocking_mode = {s}\n\n", .{
        if (httpz.blockingMode()) "true (testing the bug path)" else "false (bug only affects blocking mode)",
    });

    // ── Test 1: Stop with no connections ─────────────────────────────
    print("[Test 1] start -> stop (no connections)...\n", .{});
    {
        var server = try Server.init(std.heap.page_allocator, .{
            .address = .localhost(19224),
            .thread_pool = .{ .count = 2 }, // keep small for repro
        }, {});

        var router = try server.router(.{});
        router.get("/", noop, .{});

        const listen_thread = try server.listenInNewThread();
        std.Thread.sleep(200 * std.time.ns_per_ms);

        print("  calling stop()...\n", .{});
        server.stop();

        print("  joining listen thread...\n", .{});
        const watchdog = try std.Thread.spawn(.{}, watchdog5s, .{});
        listen_thread.join();
        watchdog.detach();

        print("  PASS\n\n", .{});
        server.deinit();
    }

    // ── Test 2: Stop with an active keep-alive connection ────────────
    print("[Test 2] start -> connect -> stop (active connection)...\n", .{});
    {
        var server = try Server.init(std.heap.page_allocator, .{
            .address = .localhost(19225),
            .timeout = .{ .keepalive = 300 },
            .thread_pool = .{ .count = 2 },
        }, {});

        var router = try server.router(.{});
        router.get("/", noop, .{});

        const listen_thread = try server.listenInNewThread();
        std.Thread.sleep(200 * std.time.ns_per_ms);

        // Open a keep-alive connection to occupy a pool thread
        const conn = std.net.tcpConnectToHost(std.heap.page_allocator, "127.0.0.1", 19225) catch |err| {
            print("  SKIP (connect failed: {})\n\n", .{err});
            server.stop();
            listen_thread.join();
            server.deinit();
            return;
        };
        _ = conn.write("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n") catch {};
        std.Thread.sleep(100 * std.time.ns_per_ms);

        print("  calling stop() with active connection...\n", .{});
        server.stop();

        print("  joining listen thread...\n", .{});
        const watchdog = try std.Thread.spawn(.{}, watchdog5s, .{});
        listen_thread.join();
        watchdog.detach();

        conn.close();
        print("  PASS\n\n", .{});
        server.deinit();
    }

    print("=== All tests passed ===\n", .{});
}

fn noop(_: *httpz.Request, res: *httpz.Response) !void {
    res.body = "ok";
}

fn watchdog5s() void {
    std.Thread.sleep(5 * std.time.ns_per_s);
    print("\n  FAIL -- shutdown hung for >5s. This is the bug.\n", .{});
    std.process.exit(1);
}
