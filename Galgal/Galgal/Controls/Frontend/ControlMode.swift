//
//  ControlMode.swift
//  Galgal
//

import Foundation
import GameController

let mode = ControlMode.mode

public enum ControlModeLiteral: String {
    case textInput
    case cameraRotate
    case arbitraryClick
    case off
    case editor
}
// This class handles different control logic under different control mode

public class ControlMode: Equatable {
    static public let mode = ControlMode()

    private var controlMode = ControlModeLiteral.off

    private var keyboardAdapter: KeyboardEventAdapter!
    private var mouseAdapter: MouseEventAdapter!
    private var controllerAdapter: ControllerEventAdapter!
    private var keyWindowObserver: NSObjectProtocol?

    public func cursorHidden() -> Bool {
        return mouseAdapter?.cursorHidden() ?? false
    }

    public func initialize() {
        if AppConfig.shared.noKMOnInput {
            setupTextInputObservers()
            set(.arbitraryClick)
        } else {
            set(.off)
        }

        setupGameController()
        setupKeyboard()
        if AppConfig.shared.enableScrollWheel {
            setupScrollWheel()
        }

        // Mouse polling rate as high as 1000 causes issue to some games
        setupMouseMoved(maxPollingRate: 125)
        setupMouseButtons()

        if AppConfig.shared.resizableWindow {
            initializeResizableWindowSupport()
        }

        ActionDispatcher.build()
    }

    private func setupTextInputObservers() {
        let center = NotificationCenter.default
        let main = OperationQueue.main
        center.addObserver(forName: UITextField.textDidEndEditingNotification, object: nil, queue: main) { _ in
            ModeAutomaton.onUITextInputEndEdit()
            Toucher.writeLog(logMessage: "uitextinput end edit")
        }
        center.addObserver(forName: UITextField.textDidBeginEditingNotification, object: nil, queue: main) { _ in
            ModeAutomaton.onUITextInputBeginEdit()
            Toucher.writeLog(logMessage: "uitextinput begin edit")
        }
        center.addObserver(forName: UITextView.textDidEndEditingNotification, object: nil, queue: main) { _ in
            ModeAutomaton.onUITextInputEndEdit()
            Toucher.writeLog(logMessage: "uitextinput end edit")
        }
        center.addObserver(forName: UITextView.textDidBeginEditingNotification, object: nil, queue: main) { _ in
            ModeAutomaton.onUITextInputBeginEdit()
            Toucher.writeLog(logMessage: "uitextinput begin edit")
        }
    }

    private func setupGameController() {
        let center = NotificationCenter.default
        let main = OperationQueue.main
        center.addObserver(forName: NSNotification.Name.GCControllerDidConnect, object: nil, queue: main) { _ in
            GCController.shouldMonitorBackgroundEvents = true
            GCController.current?.extendedGamepad?.valueChangedHandler = { profile, element in
                self.controllerAdapter.handleValueChanged(profile, element)
            }
        }
    }

    private func setupKeyboard() {
        GalgalInterface.shared!.setupKeyboard(
            keyboard: { keycode, pressed, isRepeat, ctrlModified in
                self.keyboardAdapter.handleKey(
                    keycode: keycode,
                    pressed: pressed,
                    isRepeat: isRepeat,
                    ctrlModified: ctrlModified
                )
            },
            swapMode: ModeAutomaton.onOption
        )
    }

    private func setupScrollWheel() {
        GalgalInterface.shared!.setupScrollWheel({ deltaX, deltaY in
            self.mouseAdapter.handleScrollWheel(deltaX: deltaX, deltaY: deltaY)
        })
    }

    private func setupMouseButtons() {
        GalgalInterface.shared!.setupMouseButton(left: true, right: false, { _, pressed in
            self.mouseAdapter.handleLeftButton(pressed: pressed)
        })

        GalgalInterface.shared!.setupMouseButton(left: false, right: false, { id, pressed in
            self.mouseAdapter.handleOtherButton(id: id, pressed: pressed)
        })

        GalgalInterface.shared!.setupMouseButton(left: false, right: true, { id, pressed in
            self.mouseAdapter.handleOtherButton(id: id, pressed: pressed)
        })
    }

    private func initializeResizableWindowSupport() {
        // Reactivate keymapping once the key window is initialized
        keyWindowObserver = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification,
            object: nil, queue: .main) { _ in
            ActionDispatcher.build()
            if let observer = self.keyWindowObserver {
                NotificationCenter.default.removeObserver(observer)
                self.keyWindowObserver = nil
            }
        }
        // Reactivate keymapping once the user finishes resizing the window
        NotificationCenter.default.addObserver(forName: Notification.Name("NSWindowDidEndLiveResizeNotification"),
            object: nil, queue: .main) { _ in
            ActionDispatcher.build()
        }
    }

    private func setupMouseMoved(maxPollingRate: Int) {
        let minMoveInterval =
            DispatchTimeInterval.milliseconds(1000/maxPollingRate)
        var lastMoveWhen = DispatchTime.now()
        // Repeat the return value of last processed event
        var consumed = true
        var movement: CGVector = CGVector()

        GalgalInterface.shared!.setupMouseMoved({deltaX, deltaY in
            // limit move frequency
            let now = DispatchTime.now()
            movement.dy += deltaY
            movement.dx += deltaX
            if now < lastMoveWhen.advanced(by: minMoveInterval) {
                return consumed
            }

            lastMoveWhen = now
            consumed = self.mouseAdapter.handleMove(deltaX: movement.dx, deltaY: movement.dy)
            movement.dy = 0
            movement.dx = 0
            return consumed
        })
    }

    public func set(_ mode: ControlModeLiteral) {
        let wasHidden = mouseAdapter?.cursorHidden() ?? false
        let first = mouseAdapter == nil
        keyboardAdapter = EventAdapters.keyboard(controlMode: mode)
        mouseAdapter = EventAdapters.mouse(controlMode: mode)
        controllerAdapter = EventAdapters.controller(controlMode: mode)
        controlMode = mode
        if !first {
//            Toast.showHint(title: "should hide cursor? \(mouseAdapter.cursorHidden())",
//                       text: ["current state: " + mode])
        }
        if mouseAdapter.cursorHidden() != wasHidden && settings.keymapping {
            if wasHidden {
                NotificationCenter.default.post(name: NSNotification.Name.galgalCursorWillShow,
                                                object: nil, userInfo: [:])
                if screen.fullscreen {
                    screen.switchDock(true)
                }

                if mode == .off || mode == .editor {
                    ActionDispatcher.invalidateActions()
                } else {
                    // In case any touch point failed to release
                    // (might because of system glitch)
                    // Work around random zoom in zoom out
                    ActionDispatcher.invalidateNonButtonActions()
                }

                GalgalInterface.shared!.unhideCursor()
            } else {
                NotificationCenter.default.post(name: NSNotification.Name.galgalCursorWillHide,
                                                object: nil, userInfo: [:])
                GalgalInterface.shared!.hideCursor()

                // Fix when people hold fake mouse while pressing option
                // and it becomes random zoom in zoom out
                ActionDispatcher.invalidateNonButtonActions()

                if screen.fullscreen {
                    screen.switchDock(false)
                }
            }
            Toucher.writeLog(logMessage: "cursor show switched to \(!wasHidden)")
        }
    }

    public static func == (lhs: ControlModeLiteral, rhs: ControlMode) -> Bool {
        lhs == rhs.controlMode
    }

    public static func == (lhs: ControlMode, rhs: ControlModeLiteral) -> Bool {
        rhs == lhs
    }

    public static func == (lhs: ControlMode, rhs: ControlMode) -> Bool {
        rhs.controlMode == lhs.controlMode
    }

}

extension NSNotification.Name {
    public static let galgalCursorWillHide: NSNotification.Name
                    = NSNotification.Name("galgal.cursorWillHide")

    public static let galgalCursorWillShow: NSNotification.Name
                    = NSNotification.Name("galgal.cursorWillShow")
}
