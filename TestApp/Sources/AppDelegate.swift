//
//  AppDelegate.swift
//  OphanimTest
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = TestViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class TestViewController: UIViewController {
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "Ophanim Test Harness"
        title.font = .boldSystemFont(ofSize: 20)
        title.translatesAutoresizingMaskIntoConstraints = false

        let runButton = UIButton(type: .system)
        runButton.setTitle("Run all probes", for: .normal)
        runButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        runButton.addTarget(self, action: #selector(runAll), for: .touchUpInside)
        runButton.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(title); view.addSubview(runButton); view.addSubview(textView)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            runButton.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            runButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.topAnchor.constraint(equalTo: runButton.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        ])

        // Run once automatically so events fire even without interaction.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.runAll() }
    }

    @objc private func runAll() {
        append("▶ running all probes…")
        TestRunner.runAll { [weak self] line in self?.append(line) }
    }

    private func append(_ line: String) {
        textView.text += line + "\n"
        let end = NSRange(location: textView.text.count, length: 0)
        textView.scrollRangeToVisible(end)
    }
}
