import Foundation
import LocalAgentKit

// Writing to an agent that just exited must report an error rather than kill the service.
signal(SIGPIPE, SIG_IGN)

let delegate = RunnerListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
