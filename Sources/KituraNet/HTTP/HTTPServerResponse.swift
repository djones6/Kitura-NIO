/*
 * Copyright IBM Corporation 2016, 2017, 2018
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
 */

import NIO
import NIOHTTP1
import Foundation

/// This class implements the `ServerResponse` protocol for outgoing server
/// responses via the HTTP protocol.
public class HTTPServerResponse: ServerResponse {

    /// The channel to which the HTTP response should be written
    private weak var channel: Channel?

    /// The handler that processed the HTTP request
    private weak var handler: HTTPRequestHandler?

    /// Status code
    private var status = HTTPStatusCode.OK.rawValue

    /// HTTP status code of the response.
    public var statusCode: HTTPStatusCode? {
        get {
            return HTTPStatusCode(rawValue: status)
        }

        set (newValue) {
            if let newValue = newValue {
                status = newValue.rawValue
            }
        }
    }

    /// The HTTP headers to be sent to the client as part of the response.
    public var headers : HeadersContainer = HeadersContainer()

    /// The HTTP version to be sent in the response.
    private var httpVersion: HTTPVersion

    /// The data to be written as a part of the response.
    private var buffer: ByteBuffer

    /// Initial size of the response buffer (inherited from KituraNet)
    private static let bufferSize = 2000

    init(channel: Channel, handler: HTTPRequestHandler) {
        self.channel = channel
        self.handler = handler
        self.buffer = channel.allocator.buffer(capacity: HTTPServerResponse.bufferSize)
        let httpVersionMajor = handler.serverRequest?.httpVersionMajor ?? 0
        let httpVersionMinor = handler.serverRequest?.httpVersionMinor ?? 0
        self.httpVersion = HTTPVersion(major: httpVersionMajor, minor: httpVersionMinor)
        headers["Date"] = [SPIUtils.httpDate()]
    }

    /// Write a string as a response.
    ///
    /// - Parameter from: String data to be written.
    public func write(from string: String) throws {
        try writeAsync(from: string).wait()
    }

    public func writeAsync(from string: String) -> EventLoopFuture<Void> {
        guard let channel = channel else {
            fatalError("No channel available to write.")
        }

        return execute(on: channel.eventLoop) {
            self.buffer.write(string: string)
        }
    }

    /// Write data as a response.
    ///
    /// - Parameter from: Data object that contains the data to be written.
    public func write(from data: Data) throws {
        try writeAsync(from: data).wait()
    }

    public func writeAsync(from data: Data) -> EventLoopFuture<Void> {
        guard let channel = channel else {
            fatalError("No channel available to write.")
        }
        return execute(on: channel.eventLoop) {
            self.buffer.write(bytes: data)
        }
    }

    /// Executes task on event loop
    private func execute(on eventLoop: EventLoop, _ task: @escaping () -> Void) -> EventLoopFuture<Void> {
        if eventLoop.inEventLoop {
            task()
            return eventLoop.newSucceededFuture(result: ())
        } else {
            return eventLoop.submit {
                task()
            }
        }
    }

    /// Write a string and end sending the response.
    ///
    /// - Parameter text: String to write to a socket.
    public func end(text: String) throws {
        try endAsync(text: text).wait()
    }

    public func endAsync(text: String) -> EventLoopFuture<Void> {
        return writeAsync(from: text).then {
            return self.endAsync()
        }
    }

    /// End sending the response.
    ///
    public func end() throws {
        try endAsync().wait()
    }

    public func endAsync() -> EventLoopFuture<Void> {
        guard let channel = self.channel, let handler = self.handler else {
            fatalError("Possibly writing to a non-existing/stale connection")
        }
        let status = HTTPResponseStatus(statusCode: statusCode?.rawValue ?? 0)
        if handler.clientRequestedKeepAlive {
            headers["Connection"] = ["Keep-Alive"]
            if let maxConnections = handler.keepAliveState.requestsRemaining {
                headers["Keep-Alive"] = ["timeout=\(HTTPRequestHandler.keepAliveTimeout), max=\(Int(maxConnections))"]
            } else {
                headers["Keep-Alive"] = ["timeout=\(HTTPRequestHandler.keepAliveTimeout)"]
            }
        }

        return execute(on: channel.eventLoop) {
            self.sendResponse(channel: channel, handler: handler, status: status)
        }
    }

    /// End sending the response on an HTTP error
    private func end(with errorCode: HTTPStatusCode, withBody: Bool = false) throws {
        guard let channel = self.channel else {
            fatalError("No channel available.")
        }

        guard let handler = self.handler else {
            fatalError("No HTTP handler available")
        }

        self.statusCode = errorCode
        let status = HTTPResponseStatus(statusCode: errorCode.rawValue)

        //We don't keep the connection alive on an HTTP error
        headers["Connection"] = ["Close"]

        try execute(on: channel.eventLoop) {
            self.sendResponse(channel: channel, handler: handler, status: status, withBody: withBody)
        }.wait()
    }

    /// Send response to the client
    private func sendResponse(channel: Channel, handler: HTTPRequestHandler, status: HTTPResponseStatus, withBody: Bool = true) {
        let response = HTTPResponseHead(version: httpVersion, status: status, headers: headers.httpHeaders())
        channel.write(handler.wrapOutboundOut(.head(response)), promise: nil)
        if withBody && buffer.readableBytes > 0 {
            channel.write(handler.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }

        channel.writeAndFlush(handler.wrapOutboundOut(.end(nil)), promise: nil)
        handler.updateKeepAliveState()

        if let request = handler.serverRequest {
            Monitor.delegate?.finished(request: request, response: self)
        }
    }

    func end(with errorCode: HTTPStatusCode, message: String? = nil) throws {
        if let message = message {
            try write(from: message)
        }
        try end(with: errorCode, withBody: message != nil)
    }

    /// Reset this response object back to its initial state
    public func reset() {
        status = HTTPStatusCode.OK.rawValue
        buffer.clear()
        headers.removeAll()
        headers["Date"] = [SPIUtils.httpDate()]
    }
}
