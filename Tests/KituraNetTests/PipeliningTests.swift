/**
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import NIO
import NIOHTTP1
import Dispatch
import XCTest
@testable import KituraNet

func randomNumber(limit: Int) -> Int {
    #if os(OSX)
    return Int(arc4random_uniform(UInt32(limit)))
    #else
    let random: Int = Int(rand())
    return random > 0 ? random % limit : (-1) * random % limit
    #endif
}

class PipeliningTests : KituraNetTest {

    static var allTests : [(String, (PipeliningTests) -> () throws -> Void)] {
        return [
            ("testPipelining", testPipelining),
            ("testPipeliningSpanningPackets", testPipeliningSpanningPackets),
        ]
    }

    /// Tests that the server responds appropriately to pipelined requests.
    /// Six POST requests are sent to a test server in a single socket write. The
    /// server is expected to process them sequentially, sending six separate
    /// responses in the same order.
    func testPipelining() {
        let server = HTTPServer()
        server.delegate = Delegate()
        try! server.listen(on: 0)
        let expectation = self.expectation(description: "test pipelining")
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let clientChannel = try! ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().then {
                    channel.pipeline.add(handler: PipelinedRequestsHandler(with: expectation))
                }
            }
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .connect(host: "localhost", port: server.port!).wait()
        let request = HTTPRequestHead(version: HTTPVersion(major: 1, minor:1), method: .GET,  uri: "/")
        for _ in 0...4 {
            clientChannel.write(NIOAny(HTTPClientRequestPart.head(request)), promise: nil)
            _ = clientChannel.write(NIOAny(HTTPClientRequestPart.end(nil)))
        }
        clientChannel.write(NIOAny(HTTPClientRequestPart.head(request)), promise: nil)
        try! clientChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()
        waitForExpectations(timeout: 10)
    }

    /// Tests that the server responds appropriately to pipelined requests.
    /// Six POST requests are sent to a test server in a pipelined fashion, but
    /// spanning several packets. It is necessary to sleep between writes to allow
    /// the server time to receive and process the data.
    func testPipeliningSpanningPackets() {
        let server = HTTPServer()
        server.delegate = Delegate()
        try! server.listen(on: 0)
        let expectation = self.expectation(description: "test pipelining spanning packets")
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let clientChannel = try! ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().then {
                    channel.pipeline.add(handler: PipelinedRequestsHandler(with: expectation))
                }
            }
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .connect(host: "localhost", port: server.port!).wait()
        let request = HTTPRequestHead(version: HTTPVersion(major: 1, minor:1), method: .POST,  uri: "/")
        for _ in 0...5 {
            clientChannel.write(NIOAny(HTTPClientRequestPart.head(request)), promise: nil)
            let buffer = BufferList()
            buffer.append(data: Data(count: randomNumber(limit: 8*1024)))
            clientChannel.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(buffer.byteBuffer))), promise: nil)
            _ = clientChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil)))
            usleep(100)
        }
        waitForExpectations(timeout: 10)
    }
}


private class Delegate: ServerDelegate {
    var count = -1
    func handle(request: ServerRequest, response: ServerResponse) {
        response.statusCode = .OK
        DispatchQueue.global().sync {
            count += 1
        }
        try! response.end(text: "\(count)")
    }
}


private class PipelinedRequestsHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let expectedResponses = ["0", "1", "2", "3", "4", "5"]
    private let expectation: XCTestExpectation

    init(with expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    private var responses: [String] = []

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let request = self.unwrapInboundIn(data)
        switch request {
        case .head(_):
            break
        case .body(let buffer):
            let len = buffer.readableBytes
            responses.append(buffer.getString(at: 0, length: len)!)
            if responses == expectedResponses {
                expectation.fulfill()
            }
        case .end(_):
           break
        }
   }
}
