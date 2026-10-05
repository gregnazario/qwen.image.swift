import AppKit
import Foundation

struct Qwen21GenerationRequest: Sendable {
  let prompt: String
  let width: Int
  let height: Int
  let steps: Int
  let seed: UInt64
}

actor Qwen21RuntimeService {
  static let shared = Qwen21RuntimeService()

  private var process: Process?

  func generate(_ request: Qwen21GenerationRequest) async throws -> NSImage {
    let executableURL = try Self.findExecutable()
    let outputURL = FileManager.default.temporaryDirectory
      .appending(path: "qwen-image-21-\(UUID().uuidString).png")
    let logURL = FileManager.default.temporaryDirectory
      .appending(path: "qwen-image-21-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    defer {
      try? FileManager.default.removeItem(at: outputURL)
      try? FileManager.default.removeItem(at: logURL)
    }

    let logHandle = try FileHandle(forWritingTo: logURL)
    let child = Process()
    child.executableURL = executableURL
    child.arguments = [
      "--prompt", request.prompt,
      "--width", String(request.width),
      "--height", String(request.height),
      "--steps", String(request.steps),
      "--seed", String(request.seed),
      "--output", outputURL.path
    ]
    child.standardOutput = logHandle
    child.standardError = logHandle
    process = child

    let (status, diagnostic) = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        child.terminationHandler = { finishedProcess in
          try? logHandle.close()
          let diagnostic = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
          Task {
            await self.clearProcess(finishedProcess)
            continuation.resume(returning: (finishedProcess.terminationStatus, diagnostic))
          }
        }

        do {
          try child.run()
        } catch {
          try? logHandle.close()
          Task { self.clearProcess(child) }
          continuation.resume(throwing: Qwen21RuntimeError.launchFailed(error.localizedDescription))
        }
      }
    } onCancel: {
      Task { await self.cancel() }
    }

    try Task.checkCancellation()
    guard status == 0 else {
      throw Qwen21RuntimeError.generationFailed(diagnostic.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    guard let imageData = try? Data(contentsOf: outputURL), let image = NSImage(data: imageData) else {
      throw Qwen21RuntimeError.outputMissing
    }
    return image
  }

  func cancel() {
    process?.terminate()
  }

  private func clearProcess(_ finishedProcess: Process) {
    if process === finishedProcess {
      process = nil
    }
  }

  private static func findExecutable() throws -> URL {
    let executableName = "mflux-generate-qwen-2.1"
    let environment = ProcessInfo.processInfo.environment
    let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = (["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + paths)
      .map { URL(fileURLWithPath: $0).appending(path: executableName) }

    if let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
      return executable
    }
    throw Qwen21RuntimeError.runtimeMissing
  }
}

private enum Qwen21RuntimeError: LocalizedError {
  case runtimeMissing
  case launchFailed(String)
  case generationFailed(String)
  case outputMissing

  var errorDescription: String? {
    switch self {
    case .runtimeMissing:
      return "Qwen-Image-2.1 runtime not found. Install it with ‘uv tool install --upgrade mflux’, then reopen the app."
    case .launchFailed(let message):
      return "Could not start Qwen-Image-2.1: \(message)"
    case .generationFailed(let message):
      return message.isEmpty ? "Qwen-Image-2.1 generation failed." : message
    case .outputMissing:
      return "Qwen-Image-2.1 finished without writing an image."
    }
  }
}
