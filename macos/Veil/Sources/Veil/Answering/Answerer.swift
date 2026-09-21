//  The other seam. Claude today, a local llama.cpp tomorrow.

import Foundation

protocol Answerer: AnyObject {
    /// Streams tokens as they arrive. Cancelling supersedes an in-flight answer.
    func answer(question: String,
                transcript: String,
                onToken: @escaping (String) -> Void,
                onDone: @escaping (Result<Void, Error>) -> Void)
    func cancel()
}
