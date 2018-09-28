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
import NIOOpenSSL
import LoggerAPI
import Dispatch

/// This class provides a set of low level APIs for issuing HTTP requests to another server.
public class ClientRequest {
    /// The set of HTTP headers to be sent with the request.
    public var headers = [String: String]()

    /// The URL for the request
    public private(set) var url: String = ""

    /// The HTTP method (i.e. GET, POST, PUT, DELETE) for the request
    public private(set) var method: String = "get"

    /// The username to be used if using Basic Auth authentication
    public private(set) var userName: String?

    /// The password to be used if using Basic Auth authentication.
    public private(set) var password: String?

    /// The maximum number of redirects before failure.
    ///
    /// - Note: The `ClientRequest` class will automatically follow redirect responses. To
    ///        avoid redirect loops, it will at maximum follow `maxRedirects` redirects.
    public internal(set) var maxRedirects = 10

    /// If true, the "Connection: close" header will be added to the request that is sent.
    public private(set) var closeConnection = false

    /// The callback to receive the response
    public private(set) var callback: Callback

    /// The hostname of the remote server
    var hostName: String?

    /// The port number of the remote server
    var port: Int?

    /// The request body
    var bodyData: Data?

    /// Should SSL verification be enabled
    private var disableSSLVerification = false {
        didSet {
            if disableSSLVerification {
                self.sslConfig = TLSConfiguration.forClient(certificateVerification: .none)
            }
        }
    }

    /// TLS Configuration
    var sslConfig: TLSConfiguration?

    /// The current redirection count
    internal var redirectCount: Int = 0

    private var sslContext: NIOOpenSSL.SSLContext?

    /// Should HTTP/2 protocol be used
    private var useHTTP2 = false

    /// The path (uri) related to the request, starting from / and including query parameters
    private var path = ""

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    /// A future that notifies the caller of the response receipt
    public var responseReceived: EventLoopFuture<Void>?

    var responsePromise: EventLoopPromise<Void>?

    /// Client request option enum
    public enum Options {
        /// Specifies the HTTP method (i.e. PUT, POST...) to be sent in the request
        case method(String)

        /// Specifies the schema (i.e. HTTP, HTTPS) to be used in the URL of request
        case schema(String)

        /// Specifies the host name to be used in the URL of request
        case hostname(String)

        /// Specifies the port to be used in the URL of request
        case port(Int16)

        /// Specifies the path to be used in the URL of request
        case path(String)

        /// Specifies the HTTP headers to be sent with the request
        case headers([String: String])

        /// Specifies the user name to be sent with the request, when using basic auth authentication
        case username(String)

        /// Specifies the password to be sent with the request, when using basic auth authentication
        case password(String)

        /// Specifies the maximum number of redirect responses that will be followed (i.e. re-issue the
        /// request to the location received in the redirect response)
        case maxRedirects(Int)

        /// If present, the SSL credentials of the remote server will not be verified.
        case disableSSLVerification

        /// If present, the client will try to use HTTP/2 protocol for the connection.
        case useHTTP2
    }


    init(url: String, callback: @escaping Callback) {
        self.url = url
        let url = URL(string: url)!

        if let host = url.host {
            self.hostName = host
        }

        if let port = url.port {
            self.port = port
        }

        var fullPath = url.path

        // query strings and parameters need to be appended here
        if let query = url.query {
            fullPath += "?"
            fullPath += query
        }
        self.path = fullPath

        if let username = url.user {
            self.userName = username
        }
        if let password = url.password {
            self.password = password
        }
        self.callback = callback
    }

    /// Set a single option in the request.  URL parameters must be set in init()
    ///
    /// - Parameter option: an `Options` instance describing the change to be made to the request
    public func set(_ option: Options) {
        switch(option) {
        case .schema, .hostname, .port, .path, .username, .password:
            Log.error("Must use ClientRequest.init() to set URL components")
        case .method(let method):
            self.method = method
        case .headers(let headers):
            for (key, value) in headers {
                self.headers[key] = value
            }
        case .maxRedirects(let maxRedirects):
            self.maxRedirects = maxRedirects
        case .disableSSLVerification:
            self.disableSSLVerification = true
        case .useHTTP2:
            self.useHTTP2 = true
        }
    }

    /// Initializes a `ClientRequest` instance
    ///
    /// - Parameter options: An array of `Options' describing the request
    /// - Parameter callback: The closure of type `Callback` to be used for the callback.
    init(options: [Options], callback: @escaping Callback) {

        self.callback = callback

        var theSchema = "http://"
        var hostName = "localhost"
        var path = ""
        var port = ""

        for option in options  {
            switch(option) {

                case .method, .headers, .maxRedirects, .disableSSLVerification, .useHTTP2:
                    // call set() for Options that do not construct the URL
                    set(option)
                case .schema(var schema):
                    if !schema.contains("://") && !schema.isEmpty {
                      schema += "://"
                    }
                    theSchema = schema
                case .hostname(let host):
                    hostName = host
                    self.hostName = host
                case .port(let thePort):
                    port = ":\(thePort)"
                    self.port = Int(thePort)
                case .path(var thePath):
                    if thePath.first != "/" {
                      thePath = "/" + thePath
                    }
                    path = thePath
                    self.path = path
                case .username(let userName):
                    self.userName = userName
                case .password(let password):
                    self.password = password
            }
        }

        // Support for Basic HTTP authentication
        let user = self.userName ?? ""
        let pwd = self.password ?? ""
        var authenticationClause = ""
        // If either the userName or password are non-empty, add the authenticationClause
        if (!user.isEmpty || !pwd.isEmpty) {
          authenticationClause = "\(user):\(pwd)@"
        }

        //the url string
        url = "\(theSchema)\(authenticationClause)\(hostName)\(port)\(path)"

    }

    /// Response callback closure type
    ///
    /// - Parameter ClientResponse: The `ClientResponse` object that describes the response
    ///                            that was received from the remote server.
    public typealias Callback = (ClientResponse?) -> Void


    /// Parse an URL String into options
    ///
    /// - Parameter urlString: URL of a String type
    ///
    /// - Returns: A `ClientRequest.Options` array
    public class func parse(_ urlString: String) -> [ClientRequest.Options] {
        if let url = URL(string: urlString) {
            return parse(url)
        }
        return []
    }


    /// Parse an URL class into options
    ///
    /// - Parameter url: Foundation URL class
    ///
    /// - Returns: A `ClientRequest.Options` array
    public class func parse(_ url: URL) -> [ClientRequest.Options] {

        var options: [ClientRequest.Options] = []

        if let scheme = url.scheme {
            options.append(.schema("\(scheme)://"))
        }
        if let host = url.host {
            options.append(.hostname(host))
        }
        var fullPath = url.path
        // query strings and parameters need to be appended here
        if let query = url.query {
            fullPath += "?"
            fullPath += query
        }
        options.append(.path(fullPath))
        if let port = url.port {
            options.append(.port(Int16(port)))
        }
        if let username = url.user {
            options.append(.username(username))
        }
        if let password = url.password {
            options.append(.password(password))
        }
        return options
    }


    /// Add a string to the body of the request to be sent
    ///
    /// - Parameter from: The String to be added
    public func write(from string: String) {
        if let data = string.data(using: .utf8) {
            write(from: data)
        }
    }


    /// Add the bytes in a Data struct to the body of the request to be sent
    ///
    /// - Parameter from: The Data Struct containing the bytes to be added
    public func write(from data: Data) {
        if bodyData == nil {
            bodyData = Data()
        }
        bodyData!.append(data)
        headers["Content-Length"] = "\(bodyData!.count)" //very eagerly adding
    }


    /// Add a string to the body of the request to be sent and send the request
    /// to the remote server
    ///
    /// - Parameter from: The String to be added
    /// - Parameter close: If true, add the "Connection: close" header to the set
    ///                   of headers sent with the request
    public func end(_ data: String, close: Bool = false) {
        write(from: data)
        end(close: close)
    }


    /// Add the bytes in a Data struct to the body of the request to be sent
    /// and send the request to the remote server
    ///
    /// - Parameter from: The Data Struct containing the bytes to be added
    /// - Parameter close: If true, add the "Connection: close" header to the set
    ///                   of headers sent with the request
    public func end(_ data: Data, close: Bool = false) {
        write(from: data)
        end(close: close)
    }

    /// The channel connecting to the remote server
    var channel: Channel!

    /// Send the request to the remote server
    ///
    /// - Parameter close: If true, add the "Connection: close" header to the set
    ///                   of headers sent with the request
    public func end(close: Bool = false) {
        try! endAsync(close: close).wait()
    }

    public func endAsync(close: Bool = false) -> EventLoopFuture<Void> {
        closeConnection = close

        return connect(using: group).then { channel in
            self.sendRequest(request: self.prepareHTTPRequest(), on: channel)
        }.then {
            return self.responseReceived!
        }
    }

    func closeChannelIfRequired(channel: Channel) -> EventLoopFuture<Void> {
        if closeConnection {
            channel.close(promise: nil)
            return channel.closeFuture
        }
        return channel.eventLoop.newSucceededFuture(result: ())
    }

    func shutdownEventLoopGroup() {
        do {
            try group.syncShutdownGracefully()
        } catch {
            Log.error("ClientRequest failed to shut down the EventLoopGroup for the requested URL: \(url)")
        }
        return
    }

    private func prepareHTTPRequest() -> HTTPRequestHead {
        let hostName = URL(string: url)?.host ?? "" //TODO: what could be the failure path here

        if self.headers["Host"] == nil {
           self.headers["Host"] = hostName
        }

        self.headers["User-Agent"] = "Kitura"

        if closeConnection {
            self.headers["Connection"] = "close"
        }

        if let username = self.userName, let password = self.password {
            self.headers["Authorization"] = createHTTPBasicAuthHeader(username: username, password: password)
        }

        //If the path is empty, set it to /
        let path = self.path == "" ? "/" : self.path

        var request = HTTPRequestHead(version: HTTPVersion(major: 1, minor:1), method: HTTPMethod.method(from: self.method), uri: path)
        request.headers = HTTPHeaders.from(dictionary: self.headers)

        return request
    }

    private func connect(using group: EventLoopGroup) -> EventLoopFuture<Channel> {
        var bootstrap: ClientBootstrap

        if self.isHTTPSRequest {
            self.sslConfig = TLSConfiguration.forClient(certificateVerification: .none)
            bootstrap = initializeClientBootstrapWithSSL(eventLoopGroup: group)
        } else {
            bootstrap = initializeClientBootstrap(eventLoopGroup: group)
        }
        let hostName = URL(string: url)?.host ?? "" //TODO: what could be the failure path here

        if self.port == nil {
            self.port = isHTTPSRequest ? 443 : 80
        }
        return bootstrap.connect(host: hostName, port: Int(self.port!))
    }

    private var isHTTPSRequest: Bool {
        return "https" == URL(string: url)?.scheme!
    }

    /// Executes task on event loop
    private func execute(on eventLoop: EventLoop, _ task: @escaping () -> Void) -> EventLoopFuture<Void> {
        if eventLoop.inEventLoop {
            task()
            return eventLoop.newSucceededFuture(result: ())
        }
        return eventLoop.submit {
            task()
        }
    }

    private func sendRequest(request: HTTPRequestHead, on channel: Channel) -> EventLoopFuture<Void> {
        self.responsePromise = channel.eventLoop.newPromise()
        self.responseReceived = self.responsePromise?.futureResult
        channel.write(NIOAny(HTTPClientRequestPart.head(request)), promise: nil)
        if let bodyData = bodyData {
            let buffer = BufferList()
            buffer.append(data: bodyData)
            channel.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(buffer.byteBuffer))), promise: nil)
        }
        return channel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil)))
    }

    private func initializeClientBootstrapWithSSL(eventLoopGroup: EventLoopGroup) -> ClientBootstrap {
        if let sslConfig = self.sslConfig {
            sslContext = try! SSLContext(configuration: sslConfig)
        }
        return ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                channel.pipeline.add(handler: try! OpenSSLClientHandler(context: self.sslContext!)).then {
                    channel.pipeline.addHTTPClientHandlers().then {
                        channel.pipeline.add(handler: HTTPClientHandler(request: self))
                    }
                }
            }
    }

    private func initializeClientBootstrap(eventLoopGroup: EventLoopGroup) -> ClientBootstrap {
        return ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().then {
                    channel.pipeline.add(handler: HTTPClientHandler(request: self))
                }
            }
    }

    private func createHTTPBasicAuthHeader(username: String, password: String) -> String? {
        let authHeader = "\(username):\(password)"
        guard let data = authHeader.data(using: String.Encoding.utf8) else {
            return nil
        }
        return "Basic \(data.base64EncodedString)"
    }
}

extension HTTPHeaders {
    static func from(dictionary: [String: String]) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for (key, value) in dictionary {
            headers.add(name: key, value: value)
        }
        return headers
    }
}

extension HTTPMethod {
    static func method(from method: String) -> HTTPMethod {
        let methodUpperCase = method.uppercased()
        switch methodUpperCase {
        case "GET":
            return .GET
        case "PUT":
            return .PUT
        case "ACL":
            return .ACL
        case "HEAD":
            return .HEAD
        case "POST":
            return .POST
        case "COPY":
            return .COPY
        case "LOCK":
            return .LOCK
        case "MOVE":
            return .MOVE
        case "BIND":
            return .BIND
        case "LINK":
            return .LINK
        case "PATCH":
            return .PATCH
        case "TRACE":
            return .TRACE
        case "MKCOL":
            return .MKCOL
        case "MERGE":
            return .MERGE
        case "PURGE":
            return .PURGE
        case "NOTIFY":
            return .NOTIFY
        case "SEARCH":
            return .SEARCH
        case "UNLOCK":
            return .UNLOCK
        case "REBIND":
            return .REBIND
        case "UNBIND":
            return .UNBIND
        case "REPORT":
            return .REPORT
        case "DELETE":
            return .DELETE
        case "UNLINK":
            return .UNLINK
        case "CONNECT":
            return .CONNECT
        case "MSEARCH":
            return .MSEARCH
        case "OPTIONS":
            return .OPTIONS
        case "PROPFIND":
            return .PROPFIND
        case "CHECKOUT":
            return .CHECKOUT
        case "PROPPATCH":
            return .PROPPATCH
        case "SUBSCRIBE":
            return .SUBSCRIBE
        case "MKCALENDAR":
            return .MKCALENDAR
        case "MKACTIVITY":
            return .MKACTIVITY
        case "UNSUBSCRIBE":
            return .UNSUBSCRIBE
        default:
            return HTTPMethod.RAW(value: methodUpperCase)
        }

    }
}

/// The ChannelInboundHandler for ClientRequest
class HTTPClientHandler: ChannelInboundHandler {

     /// The ClientRequest for which we installed this handler
     private let clientRequest: ClientRequest

     /// The ClientResponse object for the response
     private var clientResponse: ClientResponse = ClientResponse()

     init(request: ClientRequest) {
         self.clientRequest = request
     }

     public typealias InboundIn = HTTPClientResponsePart

     /// Read the header, body and trailer. Redirection is handled in the trailer case.
     public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
         let response = self.unwrapInboundIn(data)
         switch response {
         case .head(let header):
             clientResponse._headers = header.headers
             clientResponse.httpVersionMajor = header.version.major
             clientResponse.httpVersionMinor = header.version.minor
             clientResponse.statusCode = HTTPStatusCode(rawValue: Int(header.status.code))!
         case .body(var buffer):
             if clientResponse.buffer == nil {
                 clientResponse.buffer = BufferList(with: buffer)
             } else {
                 clientResponse.buffer!.byteBuffer.write(buffer: &buffer)
             }
         case .end(_):
            defer {
                clientRequest.closeChannelIfRequired(channel: ctx.channel).whenComplete {
                    self.clientRequest.shutdownEventLoopGroup()
                }
            }

            if clientResponse.statusCode == .movedTemporarily || clientResponse.statusCode == .movedPermanently {
                self.clientRequest.redirectCount += 1
                if self.clientRequest.redirectCount < self.clientRequest.maxRedirects {
                    guard let url = clientResponse.headers["Location"]?.first else { fatalError("Redirected but no Location header") }
                    if url.starts(with: "/") {
                        let scheme = URL(string: clientRequest.url)?.scheme
                        let request = ClientRequest(options: [.schema(scheme!),
                                                              .hostname(clientRequest.hostName!),
                                                              .port(Int16(clientRequest.port!)),
                                                              .path(url)],
                                                    callback: clientRequest.callback)
                        request.maxRedirects = self.clientRequest.maxRedirects - 1
                        request.endAsync().whenComplete {
                           self.clientRequest.responsePromise?.succeed(result: ())
                        }
                    } else {
                        let request = ClientRequest(url: url, callback: clientRequest.callback)
                        request.maxRedirects = self.clientRequest.maxRedirects - 1
                        request.endAsync().whenComplete {
                            self.clientRequest.responsePromise?.succeed(result: ())
                        }
                    }
                } else {
                    self.clientRequest.callback(self.clientResponse)
                    self.clientRequest.responsePromise?.succeed(result: ())
                }
            } else {
                self.clientRequest.callback(self.clientResponse)
                self.clientRequest.responsePromise?.succeed(result: ())

            }
         }
     }
}
