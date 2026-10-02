import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var payloadText = ""
    @State private var endpoint = ""
    @State private var allowLoopbackHTTP = false
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "phone.connection.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("CallRelay")
                            .font(.largeTitle).bold()
                        Text("扫码或粘贴控制台生成的配对内容，即可连接你的号码与设备。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section("配对内容") {
                    TextEditor(text: $payloadText)
                        .frame(minHeight: 120)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("配对内容")
                    Button {
                        if let clip = UIPasteboard.general.string { payloadText = clip }
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        showScanner = true
                    } label: {
                        Label("扫描二维码", systemImage: "qrcode.viewfinder")
                    }
                }

                Section {
                    DisclosureGroup("高级选项") {
                        TextField("https://gateway.example.com", text: $endpoint)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("允许本机 HTTP 调试（仅 localhost）", isOn: $allowLoopbackHTTP)
                            .font(.subheadline)
                    }
                }

                if let error = model.pairingError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button {
                        Task {
                            await model.pair(
                                payloadText: payloadText,
                                endpointOverride: endpoint,
                                allowLoopbackHTTP: allowLoopbackHTTP
                            )
                        }
                    } label: {
                        if model.isPairing {
                            HStack {
                                ProgressView()
                                Text("正在配对…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Text("完成配对").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(payloadText.trimmingCharacters(in: .whitespaces).isEmpty || model.isPairing)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                #if DEBUG
                Section {
                    Button {
                        model.enterDemo()
                    } label: {
                        Label("演示模式（离线）", systemImage: "wand.and.stars")
                    }
                }
                #endif
            }
            .navigationTitle("配对网关")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Only when re-pairing from a live session: a first-time
                // onboarding has nothing to cancel back to.
                if model.isPaired {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { model.cancelRepair() }
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    payloadText = code
                    showScanner = false
                }
            }
        }
    }
}

// MARK: - QR scanner

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) { }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCode: (String) -> Void
        private var handled = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !handled,
                  let object = objects.first as? AVMetadataMachineReadableCodeObject,
                  object.type == .qr,
                  let value = object.stringValue else { return }
            handled = true
            onCode(value)
        }
    }
}

final class ScannerController: UIViewController {
    var coordinator: QRScannerView.Coordinator?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private let infoLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async { self?.configure(granted: granted) }
        }
        infoLabel.text = "将网关配对二维码对准取景框"
        infoLabel.textColor = .white
        infoLabel.font = .preferredFont(forTextStyle: .footnote)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)
        NSLayoutConstraint.activate([
            infoLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            infoLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
    }

    private func configure(granted: Bool) {
        guard granted,
              let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            infoLabel.text = "相机不可用，请改用粘贴配对内容"
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.layer.bounds
        view.layer.insertSublayer(layer, at: 0)
        preview = layer
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.layer.bounds
    }
}
