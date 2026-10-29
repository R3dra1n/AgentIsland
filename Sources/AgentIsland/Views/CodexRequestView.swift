import SwiftUI

struct CodexRequestView: View {
    @ObservedObject var appState: AppState
    var onDismiss: (() -> Void)?
    @State private var answers: [String: String] = [:]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))
                Text("Codex 待处理请求")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.primary)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if appState.codexPendingRequests.isEmpty {
                        Text("当前没有待处理请求")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    ForEach(appState.codexPendingRequests) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(String(request.sessionID.prefix(12)))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            
                            if request.desktopMethod == nil {
                                Text("尚未获得实时请求详情。")
                                    .font(.system(size: 11))
                                Button {
                                    onDismiss?()
                                    CodexActionController.focus(request.sessionID)
                                } label: {
                                    Text("在 Codex 桌面端查看")
                                        .font(.system(size: 9))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                                .tint(.blue)
                            } else if request.isQuestion {
                                ForEach(request.questions) { question in
                                    Text(question.title)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.primary.opacity(0.85))
                                    
                                    ForEach(question.options, id: \.self) { option in
                                        HStack {
                                            Text(option)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(.primary.opacity(0.85))
                                            Spacer()
                                            Button {
                                                answers[request.id + question.id] = option
                                                if request.questions.count == 1 {
                                                    CodexActionController.submit(request, state: appState, answers: [question.id: option])
                                                }
                                            } label: {
                                                Text(answers[request.id + question.id] == option ? "已选" : "选择")
                                                    .font(.system(size: 9))
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.mini)
                                            .tint(.blue)
                                            .accessibilityLabel("选择：\(option)")
                                        }
                                        .padding(.vertical, 2)
                                    }
                                    TextField("输入自定义答案", text: Binding(
                                        get: { answers[request.id + question.id] ?? "" },
                                        set: { answers[request.id + question.id] = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11))
                                }
                                Button("提交完整回答") {
                                    let values = Dictionary(uniqueKeysWithValues: request.questions.map {
                                        ($0.id, answers[request.id + $0.id] ?? "")
                                    })
                                    CodexActionController.submit(request, state: appState, answers: values)
                                }
                                .controlSize(.mini)
                                .disabled(request.questions.isEmpty || request.questions.contains {
                                    (answers[request.id + $0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                })
                            } else {
                                Text(request.context ?? "Codex 正在请求您的确认")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.primary.opacity(0.85))
                                
                                HStack {
                                    Button {
                                        onDismiss?()
                                        CodexActionController.submit(request, state: appState, approve: true)
                                    } label: {
                                        Text("允许一次")
                                            .font(.system(size: 9))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.mini)
                                    .tint(.blue)
                                    
                                    Button {
                                        onDismiss?()
                                        CodexActionController.submit(request, state: appState, approve: false)
                                    } label: {
                                        Text("拒绝")
                                            .font(.system(size: 9))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                            }
                        }
                        .disabled(appState.codexActionInFlight)
                        
                        if request.id != appState.codexPendingRequests.last?.id {
                            Divider()
                        }
                    }
                    
                    if let feedback = appState.codexActionFeedback {
                        Text(feedback)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }
}
