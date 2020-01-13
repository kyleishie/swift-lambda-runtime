import Foundation
import NIOFoundationCompat
import NIO
import NIOHTTP1
import Base64Kit

// https://github.com/aws/aws-lambda-go/blob/master/events/apigw.go

public struct APIGateway {
  
  /// APIGatewayRequest contains data coming from the API Gateway
  public struct Request {
    
    public struct Context: Codable {
      
      public struct Identity: Codable {
        public let cognitoIdentityPoolId: String?
        
        public let apiKey: String?
        public let userArn: String?
        public let cognitoAuthenticationType: String?
        public let caller: String?
        public let userAgent: String?
        public let user: String?
        
        public let cognitoAuthenticationProvider: String?
        public let sourceIp: String?
        public let accountId: String?
      }
      
      public let resourceId: String?
      public let apiId: String
      public let resourcePath: String
      public let httpMethod: String
      public let requestId: String
      public let accountId: String
      public let stage: String
      
      public let identity: Identity
      public let extendedRequestId: String?
      public let path: String
    }
    
    public let resource: String?
    public let path: String
    public let httpMethod: HTTPMethod
    
    public let queryStringParameters: [String: String]?
    public let multiValueQueryStringParameters: [String:[String]]?
    public let headers: HTTPHeaders
    public let pathParameters: [String:String]?
    public let stageVariables: [String:String]?
    
    public let requestContext: Request.Context
    public let body: String?
    public let isBase64Encoded: Bool
  }
  
  public struct Response {
        
    public let statusCode     : HTTPResponseStatus
    public let headers        : HTTPHeaders?
    public let body           : String?
    public let isBase64Encoded: Bool?
        
    public init(
      statusCode: HTTPResponseStatus,
      headers: HTTPHeaders? = nil,
      body: String? = nil,
      isBase64Encoded: Bool? = nil)
    {
      self.statusCode      = statusCode
      self.headers         = headers
      self.body            = body
      self.isBase64Encoded = isBase64Encoded
    }
  }
}

// MARK: - Handler -

extension APIGateway {
  
  public static func handler(
    _ handler: @escaping (APIGateway.Request, Context) -> EventLoopFuture<APIGateway.Response>)
    -> ((NIO.ByteBuffer, Context) -> EventLoopFuture<ByteBuffer?>)
  {
    // reuse as much as possible
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    
    return { (inputBytes: NIO.ByteBuffer, ctx: Context) -> EventLoopFuture<ByteBuffer?> in
      
      let req: APIGateway.Request
      do {
        req = try decoder.decode(APIGateway.Request.self, from: inputBytes)
      }
      catch {
        return ctx.eventLoop.makeFailedFuture(error)
      }
            
      return handler(req, ctx)
        .flatMapErrorThrowing() { (error) -> APIGateway.Response in
          ctx.logger.error("Unhandled error. Responding with HTTP 500: \(error).")
          return APIGateway.Response(statusCode: .internalServerError)
        }
        .flatMapThrowing { (result: Response) -> NIO.ByteBuffer in
          return try encoder.encodeAsByteBuffer(result, allocator: ByteBufferAllocator())
        }
    }
  }
}

// MARK: - Request -

extension APIGateway.Request: Decodable {
  
  enum CodingKeys: String, CodingKey {
    
    case resource                        = "resource"
    case path                            = "path"
    case httpMethod                      = "httpMethod"
    
    case queryStringParameters           = "queryStringParameters"
    case multiValueQueryStringParameters = "multiValueQueryStringParameters"
    case headers                         = "headers"
    case multiValueHeaders               = "multiValueHeaders"
    case pathParameters                  = "pathParameters"
    case stageVariables                  = "stageVariables"
    
    case requestContext                  = "requestContext"
    case body                            = "body"
    case isBase64Encoded                 = "isBase64Encoded"
  }
  
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    
    let method = try container.decode(String.self, forKey: .httpMethod)
    self.httpMethod = HTTPMethod(rawValue: method)
    self.path = try container.decode(String.self, forKey: .path)
    self.resource = try container.decodeIfPresent(String.self, forKey: .resource)
    
    self.queryStringParameters = try container.decodeIfPresent(
      [String: String].self,
      forKey: .queryStringParameters)
    self.multiValueQueryStringParameters = try container.decodeIfPresent(
      [String: [String]].self,
      forKey: .multiValueQueryStringParameters)
    
    let awsHeaders = try container.decode([String: [String]].self, forKey: .multiValueHeaders)
    self.headers   = HTTPHeaders(awsHeaders: awsHeaders)
    
    self.pathParameters =  try container.decodeIfPresent([String:String].self, forKey: .pathParameters)
    self.stageVariables =  try container.decodeIfPresent([String:String].self, forKey: .stageVariables)
    
    self.requestContext  = try container.decode(Context.self, forKey: .requestContext)
    self.isBase64Encoded = try container.decode(Bool.self, forKey: .isBase64Encoded)
    self.body            = try container.decodeIfPresent(String.self, forKey: .body)
  }
}

extension APIGateway.Request {
  
  public func payload<Payload: Decodable>(_ type: Payload.Type, decoder: JSONDecoder = JSONDecoder()) throws -> Payload {
    let body = self.body ?? ""
        
    let capacity = body.lengthOfBytes(using: .utf8)

    // TBD: I am pretty sure, we don't need this buffer copy here.
    //      Access the strings buffer directly to get to the data.
    var buffer   = ByteBufferAllocator().buffer(capacity: capacity)
    buffer.setString(body, at: 0)
    buffer.moveWriterIndex(to: capacity)
    
    return try decoder.decode(Payload.self, from: buffer)
  }
}

// MARK: - Response -

extension APIGateway.Response: Encodable {
  
  enum CodingKeys: String, CodingKey {
    case statusCode
    case headers
    case body
    case isBase64Encoded
  }

  private struct HeaderKeys: CodingKey {
    var stringValue: String
    
    init?(stringValue: String) {
      self.stringValue = stringValue
    }
    var intValue: Int? {
      fatalError("unexpected use")
    }
    init?(intValue: Int) {
      fatalError("unexpected use")
    }
  }
  
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(statusCode.code, forKey: .statusCode)
    
    if let headers = headers {
      var headerContainer = container.nestedContainer(keyedBy: HeaderKeys.self, forKey: .headers)
      try headers.forEach { (name, value) in
        try headerContainer.encode(value, forKey: HeaderKeys(stringValue: name)!)
      }
    }
    
    try container.encodeIfPresent(body, forKey: .body)
    try container.encodeIfPresent(isBase64Encoded, forKey: .isBase64Encoded)
  }

}

extension APIGateway.Response {
  
  public init<Payload: Encodable>(
    statusCode: HTTPResponseStatus,
    headers   : HTTPHeaders? = nil,
    payload   : Payload,
    encoder   : JSONEncoder = JSONEncoder()) throws
  {
    var headers = headers ?? HTTPHeaders()
    headers.add(name: "Content-Type", value: "application/json")
    
    self.statusCode = statusCode
    self.headers    = headers
    
    let buffer = try encoder.encodeAsByteBuffer(payload, allocator: ByteBufferAllocator())
    self.body  = buffer.getString(at: 0, length: buffer.readableBytes)
    self.isBase64Encoded = false
  }
  
  /// Use this method to send any arbitrary byte buffer back to the API Gateway.
  /// Sadly Apple currently doesn't seem to be confident enough to advertise
  /// their base64 implementation publically. SAD. SO SAD. Therefore no
  /// ByteBuffer for you my friend.
  public init(
    statusCode: HTTPResponseStatus,
    headers   : HTTPHeaders? = nil,
    buffer    : NIO.ByteBuffer)
  {
    let headers = headers ?? HTTPHeaders()
    
    self.statusCode = statusCode
    self.headers    = headers
    self.body       = buffer.withUnsafeReadableBytes { (ptr) -> String in
      return String(base64Encoding: ptr)
    }
    self.isBase64Encoded = true
  }
  
}
