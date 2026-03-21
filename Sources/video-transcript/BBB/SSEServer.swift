import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// Minimal HTTP server that streams transcript segments as Server-Sent Events.
actor SSEServer {
    private let store: TranscriptStore
    private let port: Int
    private var channel: Channel?
    private var group: EventLoopGroup?

    init(store: TranscriptStore, port: Int) {
        self.store = store
        self.port = port
    }

    func start() async throws {
        let store = self.store
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(SSEHandler(store: store))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()
        self.channel = channel
        fputs("SSE server listening on http://localhost:\(port)\n", stderr)
    }

    func stop() async {
        try? await channel?.close()
        try? await group?.shutdownGracefully()
    }
}

// MARK: - NIO Handler

private final class SSEHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let store: TranscriptStore

    init(store: TranscriptStore) {
        self.store = store
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        guard case .head(let request) = part else { return }

        // CORS preflight
        if request.method == .OPTIONS {
            var headers = HTTPHeaders()
            headers.add(name: "Access-Control-Allow-Origin", value: "*")
            headers.add(name: "Access-Control-Allow-Methods", value: "GET, OPTIONS")
            headers.add(name: "Access-Control-Allow-Headers", value: "*")
            let head = HTTPResponseHead(version: request.version, status: .ok, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            return
        }

        // SSE response headers
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "Access-Control-Allow-Origin", value: "*")

        let head = HTTPResponseHead(version: request.version, status: .ok, headers: headers)
        context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)

        // Stream segments (backfill + live) in a background task.
        // Capture everything needed as local lets to avoid Sendable issues.
        let store = self.store
        let eventLoop = context.eventLoop
        let channel = context.channel

        Task { @Sendable in
            let (subscriberId, stream) = await store.subscribe()
            let encoder = JSONEncoder()

            for await segment in stream {
                guard channel.isActive else { break }

                guard let json = try? encoder.encode(segment),
                      let jsonStr = String(data: json, encoding: .utf8)
                else { continue }

                let event = "data: \(jsonStr)\n\n"
                eventLoop.execute {
                    guard channel.isActive else { return }
                    var buffer = channel.allocator.buffer(capacity: event.utf8.count)
                    buffer.writeString(event)
                    channel.writeAndFlush(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                }
            }

            await store.removeSubscriber(subscriberId)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
