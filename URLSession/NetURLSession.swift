//
//  NetURLSession.swift
//  Net
//
//  Created by Alex Rupérez on 16/3/17.
//
//

import Foundation

open class NetURLSession: Net {

    public static let shared: Net = NetURLSession(.shared)

    public static let defaultCache: URLCache = {
        let defaultMemoryCapacity = 4 * 1024 * 1024
        let defaultDiskCapacity = 5 * defaultMemoryCapacity
        let cachesDirectoryURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let cacheURL = cachesDirectoryURL?.appendingPathComponent(String(describing: NetURLSession.self))
        var defaultDiskPath = cacheURL?.path
        #if os(OSX)
        defaultDiskPath = cacheURL?.absoluteString
        #endif
        return URLCache(memoryCapacity: defaultMemoryCapacity, diskCapacity: defaultDiskCapacity, diskPath: defaultDiskPath)
    }()

    open private(set) var session: URLSession!

    open var delegate: URLSessionDelegate? { return session.delegate }

    open var delegateQueue: OperationQueue { return session.delegateQueue }

    open var configuration: URLSessionConfiguration { return session.configuration }

    open var sessionDescription: String? {
        get {
            return session.sessionDescription
        }
        set {
            session.sessionDescription = newValue
        }
    }

    var requestInterceptors = [InterceptorToken: RequestInterceptor]()

    var responseInterceptors = [InterceptorToken: ResponseInterceptor]()

    open var retryClosure: NetTask.RetryClosure?

    open var acceptableStatusCodes = defaultAcceptableStatusCodes

    open var authChallenge: ((URLAuthenticationChallenge, (URLSession.AuthChallengeDisposition, URLCredential?) -> Swift.Void) -> Swift.Void)?

    open var serverTrust = [String: NetServerTrust]()

    public convenience init() {
        let defaultConfiguration = URLSessionConfiguration.default
        defaultConfiguration.urlCache = NetURLSession.defaultCache
        self.init(defaultConfiguration)
    }

    public init(_ urlSession: URLSession) {
        session = urlSession
    }

    public init(_ configuration: URLSessionConfiguration, delegateQueue: OperationQueue? = nil, delegate: URLSessionDelegate? = nil) {
        let sessionDelegate = delegate ?? NetURLSessionDelegate(self)
        session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: delegateQueue)
    }

    public init(_ configuration: URLSessionConfiguration, challengeQueue: OperationQueue? = nil, authenticationChallenge: @escaping (URLAuthenticationChallenge, (URLSession.AuthChallengeDisposition, URLCredential?) -> Swift.Void) -> Swift.Void) {
        session = URLSession(configuration: configuration, delegate: NetURLSessionDelegate(self), delegateQueue: challengeQueue)
        authChallenge = authenticationChallenge
    }

    public init(_ configuration: URLSessionConfiguration, challengeQueue: OperationQueue? = nil, serverTrustPolicies: [String: NetServerTrust]) {
        session = URLSession(configuration: configuration, delegate: NetURLSessionDelegate(self), delegateQueue: challengeQueue)
        serverTrust = serverTrustPolicies
    }

    @discardableResult open func addRequestInterceptor(_ interceptor: @escaping RequestInterceptor) -> InterceptorToken {
        let token = InterceptorToken()
        requestInterceptors[token] = interceptor
        return token
    }

    @discardableResult open func addResponseInterceptor(_ interceptor: @escaping ResponseInterceptor) -> InterceptorToken {
        let token = InterceptorToken()
        responseInterceptors[token] = interceptor
        return token
    }

    @discardableResult open func removeInterceptor(_ token: InterceptorToken) -> Bool {
        guard requestInterceptors.removeValue(forKey: token) != nil else {
            return responseInterceptors.removeValue(forKey: token) != nil
        }
        return true
    }

    deinit {
        authChallenge = nil
        retryClosure = nil
        session.invalidateAndCancel()
        session = nil
    }
    
}

extension NetURLSession {

    func urlRequest(_ netRequest: NetRequest) -> URLRequest {
        var builder = netRequest.builder()
        requestInterceptors.values.forEach { interceptor in
            builder = interceptor(builder)
        }
        return builder.build().urlRequest
    }

    func netRequest(_ url: URL, cache: NetRequest.NetCachePolicy? = nil, timeout: TimeInterval? = nil) -> NetRequest {
        let cache = cache ?? NetRequest.NetCachePolicy(rawValue: session.configuration.requestCachePolicy.rawValue) ?? .useProtocolCachePolicy
        let timeout = timeout ?? session.configuration.timeoutIntervalForRequest
        return NetRequest(url, cache: cache, timeout: timeout)
    }

    func netTask(_ urlSessionTask: URLSessionTask, _ request: NetRequest? = nil) -> NetTask {
        if let currentRequest = urlSessionTask.currentRequest {
            return NetTask(urlSessionTask, request: currentRequest.netRequest)
        } else if let originalRequest = urlSessionTask.originalRequest {
            return NetTask(urlSessionTask, request: originalRequest.netRequest)
        }
        return NetTask(urlSessionTask, request: request)
    }

    func netResponse(_ response: URLResponse?, _ netTask: NetTask? = nil, _ responseObject: Any? = nil) -> NetResponse? {
        var netResponse: NetResponse?
        if let httpResponse = response as? HTTPURLResponse {
            netResponse = NetResponse(httpResponse, netTask, responseObject)
        } else if let response = response {
            netResponse = NetResponse(response, netTask, responseObject)
        }
        guard let response = netResponse else {
            return nil
        }
        var builder = response.builder()
        responseInterceptors.values.forEach { interceptor in
            builder = interceptor(builder)
        }
        return builder.build()
    }

    func netError(_ error: Error?, _ responseObject: Any? = nil, _ response: URLResponse? = nil) -> NetError? {
        if let error = error {
            return .net(code: error._code, message: error.localizedDescription, headers: (response as? HTTPURLResponse)?.allHeaderFields, object: responseObject, underlying: error)
        } else if let httpResponse = response as? HTTPURLResponse, !acceptableStatusCodes.contains(httpResponse.statusCode) {
            return .net(code: httpResponse.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode), headers: httpResponse.allHeaderFields, object: responseObject, underlying: error)
        }
        return nil
    }

    func process(_ netTask: NetTask?, _ netResponse: NetResponse?, _ netError: NetError?) {
        netTask?.response = netResponse
        netTask?.error = netError
        if let request = netTask?.request, let retryCount = netTask?.retryCount, netTask?.retryClosure?(netResponse, netError, retryCount) == true || retryClosure?(netResponse, netError, retryCount) == true {
            let retryTask = self.data(netTask?.request ?? request)
            netTask?.netTask = retryTask.netTask
            netTask?.state = .suspended
            netTask?.retryCount += 1
            retryTask.progressClosure = { progress in
                netTask?.progress = progress
                netTask?.progressClosure?(progress)
            }
            retryTask.completionClosure = { response, error in
                netTask?.metrics = retryTask.metrics
                self.process(netTask, response, error)
            }
            netTask?.resume()
        } else {
            netTask?.dispatchSemaphore?.signal()
            netTask?.completionClosure?(netResponse, netError)
        }
    }

}
