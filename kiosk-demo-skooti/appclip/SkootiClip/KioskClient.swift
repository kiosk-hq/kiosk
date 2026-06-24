// KioskClient.swift — POST /kiosk/exec to fetch the unlock MAC
//
// Wire contract (must match unlock_flow.rb and the server's exec controller):
//
//   Request
//   ───────
//   POST <kioskBaseURL>/kiosk/exec
//   Authorization: Bearer <agent_token>
//   Content-Type: application/json
//
//   {
//     "command": "run",
//     "body": {
//       "name":           "unlock",
//       "nonce":          "<32 lowercase hex chars — from the BLE challenge read>",
//       "reservation_id": "<uuid>"
//     }
//   }
//
//   Response — HTTP 200
//   ───────────────────
//   {
//     "value": {
//       "mac": "<64 lowercase hex chars — HMAC-SHA256>",
//       "alg": "HMAC-SHA256"
//     }
//   }
//
// Cross-checked against:
//   oss/kiosk-demo-skooti/unlock_flow.rb  lines 194-205  (POST shape)
//   oss/kiosk-server/lib/kiosk/server/unlock_authority.rb  (mac generation)

import Foundation

actor KioskClient {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = Configuration.kioskBaseURL,
         session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // ────────────────────────────────────────────────────────────
    // MARK: — unlock
    // ────────────────────────────────────────────────────────────
    //
    // Returns the 64-char hex MAC string on success.
    // Throws KioskError on HTTP error or unexpected response shape.

    func unlock(
        bearerToken: String,
        reservationId: String,
        nonce: String          // 32 lowercase hex chars from the BLE challenge
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("kiosk/exec")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")

        // Build the exact request body that unlock_flow.rb sends.
        let body: [String: Any] = [
            "command": "run",
            "body": [
                "name":           "unlock",
                "nonce":          nonce,
                "reservation_id": reservationId
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw KioskError.networkError(reason: "Non-HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw KioskError.httpError(status: http.statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(UnlockResponse.self, from: data)
        let mac = decoded.value.mac

        // Sanity-check: the firmware expects exactly 64 lowercase hex chars.
        guard mac.count == 64, mac.allSatisfy({ $0.isHexDigit }) else {
            throw KioskError.malformedMAC(received: mac)
        }

        return mac
    }
}

// ────────────────────────────────────────────────────────────
// MARK: — Error types
// ────────────────────────────────────────────────────────────

enum KioskError: LocalizedError {
    case networkError(reason: String)
    case httpError(status: Int, body: String)
    case malformedMAC(received: String)

    var errorDescription: String? {
        switch self {
        case .networkError(let r):   return "Network error: \(r)"
        case .httpError(let s, _):   return "Server returned HTTP \(s)"
        case .malformedMAC(let m):   return "Malformed MAC from server (\(m.prefix(16))…)"
        }
    }
}
