import Foundation

/// Prefer terminal build diagnostics over unrelated account-manager warnings.
public enum CommandDiagnostics {
    public static func failureText(_ output: String) -> String {
        let errors = output.components(separatedBy: .newlines).filter {
            $0.lowercased().contains(": error:")
        }
        return errors.isEmpty ? output : errors.joined(separator: "\n")
    }

    public static func isNetworkFailure(_ message: String) -> Bool {
        let text = failureText(message).lowercased()
        let codes = [-1001, -1003, -1004, -1005, -1006, -1009, -1018, -1020]
        return codes.contains { code in
            text.range(of: #"(?:nsurlerrordomain\s+code\s*=\s*|underlying error code\s+)"# + String(code) + #"\b"#,
                       options: .regularExpression) != nil
        } || text.contains("nsurlerrorcannotconnecttohost") || text.contains("network connection was lost")
    }

    public static func retryMessage(_ output: String) -> String? {
        let text = failureText(output).lowercased()
        if isNetworkFailure(text) {
            return "开发服务网络连接失败；6 小时后自动重试。"
        }
        if text.contains("com.apple.dt.coredeviceerror error 4016") {
            return "iPhone 开发连接暂不可用；请保持同一 Wi-Fi 或连接 USB，6 小时后自动重试。"
        }
        return nil
    }
}
