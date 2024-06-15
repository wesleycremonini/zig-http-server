const std = @import("std");
const net = std.net;
const fs = std.fs;
const mem = std.mem;

pub const ServeFileError = error{
    HeaderMalformed,
    MethodNotSupported,
    ProtoNotSupported,
    UnknownMimeType,
};

const mimeTypes = .{
    .{ ".html", "text/html" },
    .{ ".css", "text/css" },
    .{ ".png", "image/png" },
    .{ ".jpg", "image/jpeg" },
    .{ ".gif", "image/gif" },
};

pub fn main() !void {
    const addr_to_listen_to = try net.Address.resolveIp("0.0.0.0", 7777);
    var listener = try addr_to_listen_to.listen(.{ .reuse_address = true });

    while (listener.accept()) |conn| {
        var reqBuf: [4096]u8 = undefined;
        var reqBytes: usize = 0;

        while (conn.stream.read(reqBuf[reqBytes..])) |lineBytes| {
            if (lineBytes == 0) break;
            reqBytes += lineBytes;
            if (endOfRequestReached(reqBuf[0..reqBytes])) break;
        } else |read_err| {
            return read_err;
        }

        const req = reqBuf[0..reqBytes];
        if (req.len == 0) continue;

        const headers = try parseHeaders(req);
        const path = try parsePath(headers.requestLine);
        const content = localFileGetContent(path) catch |err| {
            if (err == error.FileNotFound) {
                _ = try conn.stream.writer().write(notFound());
                continue;
            } else return err;
        };

        const httpHead =
            "HTTP/1.1 200 OK \r\n" ++
            "Connection: close\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {}\r\n" ++
            "\r\n";

        _ = try conn.stream.writer().print(httpHead, .{ getMimeFromPath(path), content.len });
        _ = try conn.stream.writer().write(content);
    } else |err| {
        std.debug.print("error in accept: {}\n", .{err});
    }
}

pub fn endOfRequestReached(req: []const u8) bool {
    return mem.containsAtLeast(u8, req, 1, "\r\n\r\n");
}

const HeaderNames = enum {
    Host,
    @"User-Agent",
};

const HTTPHeader = struct {
    requestLine: []const u8,
    host: []const u8,
    userAgent: []const u8,

    pub fn print(self: HTTPHeader) void {
        std.debug.print("requestLine: {}\n", .{self.requestLine});
        std.debug.print("host: {}\n", .{self.host});
        std.debug.print("userAgent: {}\n", .{self.userAgent});
    }
};

pub fn parseHeaders(header: []const u8) !HTTPHeader {
    var hs = HTTPHeader{
        .requestLine = undefined,
        .host = undefined,
        .userAgent = undefined,
    };

    var splittedHeader = mem.tokenizeSequence(u8, header, "\r\n");
    hs.requestLine = splittedHeader.next() orelse return ServeFileError.HeaderMalformed;

    while (splittedHeader.next()) |line| {
        const nameSlice = mem.sliceTo(line, ':');
        if (nameSlice.len == line.len) return ServeFileError.HeaderMalformed;

        const headerKey = std.meta.stringToEnum(HeaderNames, nameSlice) orelse continue;

        const headerValue = mem.trimLeft(u8, line[nameSlice.len + 1 ..], " ");

        switch (headerKey) {
            .Host => hs.host = headerValue,
            .@"User-Agent" => hs.userAgent = headerValue,
        }
    }

    return hs;
}

pub fn parsePath(requestLine: []const u8) ![]const u8 {
    var splittedRequestLine = mem.tokenizeScalar(u8, requestLine, ' ');

    const method = splittedRequestLine.next().?;
    // only supporting GET method for now xD
    if (!mem.eql(u8, method, "GET")) return ServeFileError.MethodNotSupported;

    const path = splittedRequestLine.next().?;
    if (path.len <= 0) return error.NoPath;

    const proto = splittedRequestLine.next().?;
    if (!mem.eql(u8, proto, "HTTP/1.1")) return ServeFileError.ProtoNotSupported;

    if (mem.eql(u8, path, "/")) return "/xd.html";

    return path;
}

pub fn localFileGetContent(path: []const u8) ![]u8 {
    const localPath = path[1..];

    const file = try fs.cwd().openFile(localPath, .{});
    defer file.close();
    const memory = std.heap.page_allocator;
    const maxSize = std.math.maxInt(usize);

    return try file.readToEndAlloc(memory, maxSize);
}

pub fn notFound() []const u8 {
    return "HTTP/1.1 404 NOT FOUND \r\n" ++
        "Connection: close\r\n" ++
        "Content-Type: text/html; charset=utf8\r\n" ++
        "Content-Length: 33\r\n" ++
        "\r\n" ++
        "YOU ARE A QUICHE EATER";
}

pub fn getMimeFromPath(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);

    inline for (mimeTypes) |kv| {
        if (mem.eql(u8, extension, kv[0])) {
            return kv[1];
        }
    }

    return "application/octet-stream";
}
