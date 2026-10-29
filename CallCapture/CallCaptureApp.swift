//
//  CallCaptureApp.swift
//  CallCapture
//
//  Created by John Souchak on 10/28/26.
//

import AppKit
import SwiftUI

@main
struct CallCaptureApp: App {
    @State private var recorder = Recorder()

    var body: some Scene {
        MenuBarExtra {
            Text(recorder.statusText)

            Divider()

            Button(recorder.isRecording ? "Stop Recording" : "Start Recording") {
                recorder.toggle()
            }
            .disabled(recorder.state == .starting)

            Divider()

            Button("Open Last Transcript") {
                recorder.openLastTranscript()
            }
            .disabled(recorder.lastTranscriptURL == nil)

            Button("Open Recordings Folder") {
                recorder.openRecordingsFolder()
            }

            Divider()

            Button("Quit CallCapture") {
                Task {
                    await recorder.stopRecording(transcribe: false)
                    NSApplication.shared.terminate(nil)
                }
            }
            .keyboardShortcut("q")
        } label: {
            Image(nsImage: Self.menuBarIcon(recording: recorder.isRecording))
        }
        .menuBarExtraStyle(.menu)
    }

    /// Menu-bar images are templates (monochrome) by default, so the red
    /// recording icon is built as a non-template image.
    private static func menuBarIcon(recording: Bool) -> NSImage {
        let name = recording ? "record.circle.fill" : "record.circle"
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "CallCapture") ?? NSImage()
        guard recording else {
            base.isTemplate = true
            return base
        }
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = false
        return image
    }
}
