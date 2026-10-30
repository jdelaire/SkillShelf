import Foundation

func posixCode(_ error: NSError) -> Int {
    if error.domain == NSPOSIXErrorDomain { return error.code }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        let code = posixCode(underlying)
        if code != 0 { return code }
    }
    if let domain = error.userInfo["_kCFStreamErrorDomainKey"] as? Int, domain == 1,
       let code = error.userInfo["_kCFStreamErrorCodeKey"] as? Int {
        return code
    }
    return 0
}

guard CommandLine.arguments.count == 2, let url = URL(string: CommandLine.arguments[1]) else {
    exit(64)
}
let configuration = URLSessionConfiguration.ephemeral
configuration.timeoutIntervalForRequest = 5
configuration.timeoutIntervalForResource = 5
let session = URLSession(configuration: configuration)
defer { session.invalidateAndCancel() }
do {
    let (_, response) = try await session.data(from: url)
    guard let http = response as? HTTPURLResponse else { exit(65) }
    print(http.statusCode)
} catch {
    let error = error as NSError
    print("error \(error.code) \(posixCode(error))")
}
