import SwiftUI
import AVFoundation

struct InlineQRScanner: View {
    let onCodeScanned: (String) -> Void
    @State private var isScanning = true

    var body: some View {
        QRScannerRepresentable(onCodeScanned: { code in
            isScanning = false
            onCodeScanned(code)
        }, isScanning: $isScanning)
    }
}

struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void
    @Binding var isScanning: Bool

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onCodeScanned = onCodeScanned
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        if isScanning {
            uiViewController.startScanning()
        }
    }
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasScanned = false
        startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    private func setupCamera() {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            showError("Camera not available")
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        self.captureSession = session
        self.previewLayer = previewLayer

        addCornerIndicators()
    }

    private func addCornerIndicators() {
        let cornerLength: CGFloat = 20
        let cornerWidth: CGFloat = 1.5
        let accentColor = UIColor.white

        let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 1, 1),     // Top-left
            (1, 0, -1, 1),    // Top-right
            (0, 1, 1, -1),    // Bottom-left
            (1, 1, -1, -1)    // Bottom-right
        ]

        for (xMult, yMult, _, _) in corners {
            let hBar = UIView()
            hBar.backgroundColor = accentColor
            hBar.tag = 100
            view.addSubview(hBar)

            let vBar = UIView()
            vBar.backgroundColor = accentColor
            vBar.tag = 100
            view.addSubview(vBar)

            hBar.translatesAutoresizingMaskIntoConstraints = false
            vBar.translatesAutoresizingMaskIntoConstraints = false

            let paddingH: CGFloat = 40
            let paddingTop: CGFloat = 40
            let paddingBottom: CGFloat = 80  // Extra space for the text band

            NSLayoutConstraint.activate([
                hBar.widthAnchor.constraint(equalToConstant: cornerLength),
                hBar.heightAnchor.constraint(equalToConstant: cornerWidth),
                vBar.widthAnchor.constraint(equalToConstant: cornerWidth),
                vBar.heightAnchor.constraint(equalToConstant: cornerLength),
            ])

            if xMult == 0 {
                hBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: paddingH).isActive = true
                vBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: paddingH).isActive = true
            } else {
                hBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -paddingH).isActive = true
                vBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -paddingH).isActive = true
            }

            if yMult == 0 {
                hBar.topAnchor.constraint(equalTo: view.topAnchor, constant: paddingTop).isActive = true
                vBar.topAnchor.constraint(equalTo: view.topAnchor, constant: paddingTop).isActive = true
            } else {
                hBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -paddingBottom).isActive = true
                vBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -paddingBottom).isActive = true
            }
        }
    }

    func startScanning() {
        guard captureSession?.isRunning == false else { return }
        hasScanned = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }

    func stopScanning() {
        captureSession?.stopRunning()
    }

    private func showError(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .gray
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                       didOutput metadataObjects: [AVMetadataObject],
                       from connection: AVCaptureConnection) {
        guard !hasScanned,
              let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = metadataObject.stringValue else {
            return
        }

        hasScanned = true
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        stopScanning()
        onCodeScanned?(stringValue)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }
}
