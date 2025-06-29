import ArgumentParser
import Dependencies
import Foundation
import Hummingbird
import HummingbirdCore
import NIOCore
import Ollama

extension Olleh {
    struct Serve: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start olleh"
        )

        @Option(help: "Host to listen on")
        var host: String = "127.0.0.1"

        @Option(help: "Port to listen on")
        var port: Int = 43110

        func run() throws {
            let server = OllamaServer(host: host, port: port)

            let group = DispatchGroup()
            group.enter()

            Task {
                do {
                    try await server.start()
                } catch {
                    print("Server error: \(error)")
                }
                group.leave()
            }

            group.wait()
        }
    }
}

// MARK: -

private final actor OllamaServer: Sendable {
    let host: String
    let port: Int

    private let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let string = formatter.string(from: date)
            var container = encoder.singleValueContainer()
            try container.encode(string)
        }
        return encoder
    }()

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid date format: \(string)"
                )
            }
            return date
        }
        return decoder
    }()

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    @Dependency(\.foundationModelsClient) var foundationModelsClient

    private nonisolated func approximateTokenCount(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, text.count / 4)
    }

    func start() async throws {
        let router = Router()

        // Ollama-compatible API endpoints
        router.post("/api/generate") { request, context in
            return try await self.generateCompletion(request: request)
        }

        router.post("/api/chat") { request, context in
            return try await self.chatCompletion(request: request)
        }

        router.get("/api/tags") { request, context in
            let response = try await self.listModels()
            let data = try self.jsonEncoder.encode(response)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        router.get("/api/show") { request, context in
            let response = try await self.showModel(request: request)
            let data = try self.jsonEncoder.encode(response)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(host, port: port)
            )
        )

        try await app.runService()
    }

    private func listModels() async throws -> Client.ListModelsResponse {
        let models = await foundationModelsClient.listModels()

        return Client.ListModelsResponse(
            models: models.map {
                Client.ListModelsResponse.Model(
                    name: $0,
                    modifiedAt: iso8601Formatter.string(from: Date()),
                    size: 0,
                    digest: "",
                    details: Model.Details(
                        format: "apple",
                        family: "foundation",
                        families: ["foundation"],
                        parameterSize: "unknown",
                        quantizationLevel: "unknown",
                        parentModel: nil
                    )
                )
            }
        )
    }

    private func generateCompletion(request: Request) async throws -> Response {
        let startTime = Date.now

        var bodyData = Data()
        for try await chunk in request.body.buffer(policy: .unbounded) {
            bodyData.append(contentsOf: chunk.readableBytesView)
        }

        let params = try jsonDecoder.decode([String: Value].self, from: bodyData)

        guard foundationModelsClient.isAvailable() else {
            throw FoundationModelsDependency.Error.notAvailable
        }

        // Extract parameters
        let model = params["model"]?.stringValue ?? "default"
        let prompt = params["prompt"]?.stringValue ?? ""
        let stream = params["stream"]?.boolValue ?? false

        // Extract generation parameters directly
        let generationParams = try jsonDecoder.decode(
            FoundationModelsDependency.Parameters.self,
            from: bodyData
        )

        // Calculate prompt token count approximation
        let promptTokenCount = approximateTokenCount(for: prompt)

        // Check if streaming is requested
        if stream {
            // Return streaming response
            let responseBody = ResponseBody { writer in
                do {
                    let loadStartTime = Date()
                    let streamedContent = try await self.foundationModelsClient.streamGenerate(
                        model, prompt, generationParams)
                    let loadDuration = Date().timeIntervalSince(loadStartTime)

                    var completionText = ""
                    let promptEvalStartTime = Date()

                    for try await chunk in streamedContent {
                        completionText += chunk
                        let response = Client.GenerateResponse(
                            model: Model.ID(rawValue: model) ?? "default",
                            createdAt: Date(),
                            response: chunk,
                            done: false,
                            context: nil,
                            thinking: nil,
                            totalDuration: nil,
                            loadDuration: nil,
                            promptEvalCount: nil,
                            promptEvalDuration: nil,
                            evalCount: nil,
                            evalDuration: nil
                        )

                        let data = try self.jsonEncoder.encode(response)
                        let line = String(data: data, encoding: .utf8)! + "\n"
                        try await writer.write(ByteBuffer(string: line))
                    }

                    let totalDuration = Date().timeIntervalSince(startTime)
                    let evalTokenCount = self.approximateTokenCount(for: completionText)

                    // Send final "done" response
                    let finalResponse = Client.GenerateResponse(
                        model: Model.ID(rawValue: model) ?? "default",
                        createdAt: Date(),
                        response: "",
                        done: true,
                        context: nil,
                        thinking: nil,
                        totalDuration: totalDuration,
                        loadDuration: loadDuration,
                        promptEvalCount: promptTokenCount,
                        promptEvalDuration: Date().timeIntervalSince(promptEvalStartTime),
                        evalCount: evalTokenCount,
                        evalDuration: totalDuration - loadDuration
                    )

                    let finalData = try self.jsonEncoder.encode(finalResponse)
                    let finalLine = String(data: finalData, encoding: .utf8)! + "\n"
                    try await writer.write(ByteBuffer(string: finalLine))
                    try await writer.finish(nil)
                } catch {
                    // Send error response
                    let errorResponse = Client.GenerateResponse(
                        model: Model.ID(rawValue: model) ?? "default",
                        createdAt: Date(),
                        response: "Error: \(error.localizedDescription)",
                        done: true,
                        context: nil,
                        thinking: nil,
                        totalDuration: nil,
                        loadDuration: nil,
                        promptEvalCount: nil,
                        promptEvalDuration: nil,
                        evalCount: nil,
                        evalDuration: nil
                    )

                    let errorData = try self.jsonEncoder.encode(errorResponse)
                    let errorLine = String(data: errorData, encoding: .utf8)! + "\n"
                    try await writer.write(ByteBuffer(string: errorLine))
                    try await writer.finish(nil)
                }
            }

            return Response(
                status: .ok,
                headers: [.contentType: "application/x-ndjson"],
                body: responseBody
            )
        } else {
            // Non-streaming response
            let loadStartTime = Date()
            let response = try await foundationModelsClient.generate(
                model,
                prompt,
                generationParams
            )
            let loadDuration = Date().timeIntervalSince(loadStartTime)
            let totalDuration = Date().timeIntervalSince(startTime)

            let evalTokenCount = approximateTokenCount(for: response)

            let data = try jsonEncoder.encode(
                Client.GenerateResponse(
                    model: Model.ID(rawValue: model) ?? "default",
                    createdAt: Date(),
                    response: response,
                    done: true,
                    context: nil,
                    thinking: nil,
                    totalDuration: totalDuration,
                    loadDuration: loadDuration,
                    promptEvalCount: promptTokenCount,
                    promptEvalDuration: loadDuration,
                    evalCount: evalTokenCount,
                    evalDuration: totalDuration - loadDuration
                ))

            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }
    }

    private func chatCompletion(request: Request) async throws -> Response {
        let startTime = Date()

        var bodyData = Data()
        for try await chunk in request.body.buffer(policy: .unbounded) {
            bodyData.append(contentsOf: chunk.readableBytesView)
        }

        let params = try jsonDecoder.decode([String: Value].self, from: bodyData)

        guard foundationModelsClient.isAvailable() else {
            throw FoundationModelsDependency.Error.notAvailable
        }

        // Extract parameters
        let model = params["model"]?.stringValue ?? "default"
        let stream = params["stream"]?.boolValue ?? false
        let messages: [Chat.Message]
        if let messagesValue = params["messages"] {
            let data = try jsonEncoder.encode(messagesValue)
            messages = try jsonDecoder.decode([Chat.Message].self, from: data)
        } else {
            messages = []
        }

        // Extract generation parameters directly
        let generationParams = try jsonDecoder.decode(
            FoundationModelsDependency.Parameters.self,
            from: bodyData
        )

        // Calculate prompt token count approximation
        let promptText = messages.map(\.content).joined(separator: "\n")
        let promptTokenCount = approximateTokenCount(for: promptText)

        if stream {
            // Return streaming response
            let responseBody = ResponseBody { writer in
                do {
                    let loadStartTime = Date()
                    let streamedContent = try await self.foundationModelsClient.streamChat(
                        model, messages, generationParams)
                    let loadDuration = Date().timeIntervalSince(loadStartTime)

                    var completionText = ""
                    let promptEvalStartTime = Date()

                    for try await chunk in streamedContent {
                        completionText += chunk
                        let response = Client.ChatResponse(
                            model: Model.ID(rawValue: model) ?? "default",
                            createdAt: Date(),
                            message: Chat.Message.assistant(chunk),
                            done: false,
                            totalDuration: nil,
                            loadDuration: loadDuration,
                            promptEvalCount: promptTokenCount,
                            promptEvalDuration: Date().timeIntervalSince(promptEvalStartTime),
                            evalCount: self.approximateTokenCount(for: completionText),
                            evalDuration: Date().timeIntervalSince(startTime) - loadDuration
                        )

                        let data = try self.jsonEncoder.encode(response)
                        let line = String(data: data, encoding: .utf8)! + "\n"
                        try await writer.write(ByteBuffer(string: line))
                    }

                    let totalDuration = Date().timeIntervalSince(startTime)
                    let evalTokenCount = self.approximateTokenCount(for: completionText)

                    // Send final "done" response
                    let finalResponse = Client.ChatResponse(
                        model: Model.ID(rawValue: model) ?? "default",
                        createdAt: Date(),
                        message: Chat.Message.assistant(""),
                        done: true,
                        totalDuration: totalDuration,
                        loadDuration: loadDuration,
                        promptEvalCount: promptTokenCount,
                        promptEvalDuration: Date().timeIntervalSince(promptEvalStartTime),
                        evalCount: evalTokenCount,
                        evalDuration: totalDuration - loadDuration
                    )

                    let finalData = try self.jsonEncoder.encode(finalResponse)
                    let finalLine = String(data: finalData, encoding: .utf8)! + "\n"
                    try await writer.write(ByteBuffer(string: finalLine))
                    try await writer.finish(nil)
                } catch {
                    // Send error response
                    let errorResponse = Client.ChatResponse(
                        model: Model.ID(rawValue: model) ?? "default",
                        createdAt: Date(),
                        message: Chat.Message.assistant("Error: \(error.localizedDescription)"),
                        done: true,
                        totalDuration: nil,
                        loadDuration: nil,
                        promptEvalCount: nil,
                        promptEvalDuration: nil,
                        evalCount: nil,
                        evalDuration: nil
                    )

                    let errorData = try self.jsonEncoder.encode(errorResponse)
                    let errorLine = String(data: errorData, encoding: .utf8)! + "\n"
                    try await writer.write(ByteBuffer(string: errorLine))
                    try await writer.finish(nil)
                }
            }

            return Response(
                status: .ok,
                headers: [.contentType: "application/x-ndjson"],
                body: responseBody
            )
        } else {
            // Non-streaming response
            let loadStartTime = Date()
            let response = try await foundationModelsClient.chat(
                model,
                messages,
                generationParams
            )
            let loadDuration = Date().timeIntervalSince(loadStartTime)
            let totalDuration = Date().timeIntervalSince(startTime)

            let evalTokenCount = approximateTokenCount(for: response)

            let data = try jsonEncoder.encode(
                Client.ChatResponse(
                    model: Model.ID(rawValue: model) ?? "default",
                    createdAt: Date(),
                    message: Chat.Message.assistant(response),
                    done: true,
                    totalDuration: totalDuration,
                    loadDuration: loadDuration,
                    promptEvalCount: promptTokenCount,
                    promptEvalDuration: loadDuration,
                    evalCount: evalTokenCount,
                    evalDuration: totalDuration - loadDuration
                ))

            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }
    }

    private func showModel(request: Request) async throws -> Client.ShowModelResponse {
        _ = request.uri.queryParameters["name"] ?? "default"
        return Client.ShowModelResponse(
            modelfile: "FROM apple/foundation-models",
            parameters: "{}",
            template: "{{ .Prompt }}",
            details: Model.Details(
                format: "apple",
                family: "foundation",
                families: ["foundation"],
                parameterSize: "unknown",
                quantizationLevel: "unknown",
                parentModel: nil
            ),
            info: ["license": .string("Apple Foundation Models")],
            capabilities: [.completion]
        )
    }

}
