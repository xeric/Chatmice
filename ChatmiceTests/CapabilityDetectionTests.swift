import XCTest

@testable import Chatmice

final class CapabilityDetectionTests: XCTestCase {
    override func tearDown() {
        CapabilityProbeURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testSemanticProbeResponsesAcrossProtocols() {
        let visionResponses: [(type: String, json: String)] = [
            ("deepseek", #"{"choices":[{"message":{"content":"red"}}]}"#),
            ("claude", #"{"content":[{"type":"text","text":"red"}]}"#),
            ("gemini", #"{"candidates":[{"content":{"parts":[{"text":"red"}]}}]}"#),
            ("openai-responses", #"{"output":[{"content":[{"text":"red"}]}]}"#),
            ("ollama", #"{"message":{"content":"red"}}"#)
        ]
        for response in visionResponses {
            XCTAssertTrue(
                ModelCapabilityProbe.responseProvesVision(
                    data: Data(response.json.utf8),
                    serviceType: response.type
                ),
                response.type
            )
        }

        let audioResponses: [(type: String, json: String)] = [
            ("chatgpt", #"{"choices":[{"message":{"content":"two"}}]}"#),
            ("claude", #"{"content":[{"type":"text","text":"two"}]}"#),
            ("gemini", #"{"candidates":[{"content":{"parts":[{"text":"two"}]}}]}"#),
            ("openai-responses", #"{"output":[{"content":[{"text":"two"}]}]}"#),
            ("ollama", #"{"message":{"content":"two"}}"#)
        ]
        for response in audioResponses {
            XCTAssertTrue(
                ModelCapabilityProbe.responseProvesAudio(
                    data: Data(response.json.utf8),
                    serviceType: response.type
                ),
                response.type
            )
        }

        let genericSuccess = Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)
        XCTAssertFalse(ModelCapabilityProbe.responseProvesVision(data: genericSuccess, serviceType: "chatgpt"))
        XCTAssertFalse(ModelCapabilityProbe.responseProvesAudio(data: genericSuccess, serviceType: "chatgpt"))
    }

    func testCapabilityResultsPreserveNegativeOverrides() throws {
        let serviceID = UUID()
        let key = "modelCapabilityTests.v3.\(serviceID.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let results = [
            "failed": ModelCapabilityTestResult(
                connectionSucceeded: true,
                visionSupported: false,
                audioSupported: false,
                reasoningSupported: false,
                testedAt: Date(),
                errorMessage: nil
            ),
            "verified": ModelCapabilityTestResult(
                connectionSucceeded: true,
                visionSupported: true,
                audioSupported: true,
                reasoningSupported: true,
                testedAt: Date(),
                errorMessage: nil
            )
        ]
        UserDefaults.standard.set(try JSONEncoder().encode(results), forKey: key)

        let restored = ModelCapabilityTestStore.results(for: serviceID)
        XCTAssertEqual(restored["failed"]?.visionSupported, false)
        XCTAssertEqual(restored["failed"]?.audioSupported, false)
        XCTAssertEqual(restored["failed"]?.reasoningSupported, false)
        XCTAssertEqual(restored["verified"]?.visionSupported, true)
        XCTAssertEqual(restored["verified"]?.audioSupported, true)
        XCTAssertEqual(restored["verified"]?.reasoningSupported, true)
    }

    func testAudioProbeRunsBeforeOtherOptionalCapabilities() async throws {
        var requestKinds: [String] = []
        CapabilityProbeURLProtocol.requestHandler = { request in
            let data = try requestBodyData(request)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = body["messages"] as? [[String: Any]]
            let parts = messages?.first?["content"] as? [[String: Any]] ?? []
            let kind: String
            let responseText: String
            if parts.contains(where: { $0["type"] as? String == "input_audio" }) {
                kind = "audio"
                responseText = "two"
            } else if parts.contains(where: { $0["type"] as? String == "image_url" }) {
                kind = "vision"
                responseText = "red"
            } else if body["reasoning_effort"] != nil {
                kind = "reasoning"
                responseText = "OK"
            } else {
                kind = "connection"
                responseText = "OK"
            }
            requestKinds.append(kind)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = try JSONSerialization.data(
                withJSONObject: ["choices": [["message": ["content": responseText]]]]
            )
            return (response, payload)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapabilityProbeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let config = APIServiceConfig(
            name: "Capability Probe",
            apiUrl: URL(string: "https://probe.invalid/v1")!,
            apiKey: "fixture",
            model: "multimodal-model",
            type: "chatgpt"
        )

        let result = await ModelCapabilityProbe.test(
            config: config,
            modelID: "multimodal-model",
            session: session
        )
        XCTAssertEqual(requestKinds, ["connection", "audio", "vision", "reasoning"])
        XCTAssertTrue(result.connectionSucceeded)
        XCTAssertEqual(result.audioSupported, true)
        XCTAssertEqual(result.visionSupported, true)
        XCTAssertEqual(result.reasoningSupported, true)
    }
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw try XCTUnwrap(stream.streamError) }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}
private final class CapabilityProbeURLProtocol: URLProtocol {

    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.requestHandler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
