import AppKit
import SwiftUI

@main
struct VoiceOverApp: App {
    @StateObject private var microphone = Microphone()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("VoiceOver", id: "recorder") {
            RecorderView(microphone: microphone)
                .background(WindowAccess { window in
                    delegate.microphone = microphone
                    window.delegate = delegate
                    window.titlebarAppearsTransparent = false
                    window.backgroundColor = .white
                })
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var microphone: Microphone?
    private var decisionOpen = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let microphone else { return true }
        guard microphone.hasUnsavedRecording else { microphone.releaseSavedDraft(); return true }
        guard microphone.canRequestClose else { NSSound.beep(); return false }
        guard !decisionOpen else { return false }
        decisionOpen = true
        if microphone.state == .recording { microphone.pauseOrResume() }
        microphone.requestCloseConfirmation { shouldClose in
            self.decisionOpen = false
            if shouldClose { sender.performClose(nil) }
        }
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let microphone else { return .terminateNow }
        guard microphone.hasUnsavedRecording else { microphone.releaseSavedDraft(); return .terminateNow }
        guard microphone.canRequestClose else { NSSound.beep(); return .terminateCancel }
        guard !decisionOpen, (NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })) != nil else { return .terminateCancel }
        decisionOpen = true
        if microphone.state == .recording { microphone.pauseOrResume() }
        microphone.requestCloseConfirmation { shouldTerminate in
            self.decisionOpen = false
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct WindowAccess: NSViewRepresentable {
    let register: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { register(window) } }
    }
}

private let ink = Color(red: 0.09, green: 0.15, blue: 0.25)
private let orange = Color(red: 0.94, green: 0.36, blue: 0.00)
private let paleBlue = Color(red: 0.94, green: 0.97, blue: 1.0)

private struct VoiceOverButton: ButtonStyle {
    var filled = false
    var compact = false
    var bottomAction = false
    var styleChoice = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: bottomAction ? 12.6 : (compact ? 14 : 18), weight: .semibold))
            .foregroundStyle(filled ? Color.white : ink)
            .padding(.horizontal, bottomAction ? 10 : (compact ? 12 : 22))
            .frame(height: styleChoice ? 37 : (bottomAction ? 32.2 : (compact ? 38 : 46)))
            .background(filled ? orange : .white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(orange, lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct VoiceOverSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
            Button { configuration.isOn.toggle() } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? orange : ink.opacity(0.16))
                    Circle().fill(.white).padding(3).shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                }
                .frame(width: 46, height: 26)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct VoiceOverSpeedSlider: View {
    @Binding var value: Double
    let enabled: Bool
    var body: some View {
        GeometryReader { geometry in
            let knob: CGFloat = 18
            let progress = CGFloat(max(0, min(7, value)) / 7)
            ZStack(alignment: .leading) {
                Capsule().fill(ink.opacity(0.14)).frame(height: 6)
                Capsule().fill(orange).frame(width: max(3, geometry.size.width * progress), height: 6)
                Circle().fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
                    .offset(x: progress * (geometry.size.width - knob))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                guard enabled, geometry.size.width > 0 else { return }
                value = Double(max(0, min(7, gesture.location.x / geometry.size.width * 7)).rounded())
            })
        }
        .frame(height: 24)
    }
}

struct RecorderView: View {
    @ObservedObject var microphone: Microphone
    @State private var showingSpeedHelp = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) {
                Text("V").font(.system(size: 49, weight: .bold))
                    .frame(width: 58, height: 58)
                    .background(orange.gradient, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("VoiceOver").font(.system(size: 30, weight: .bold))
                    Text("Record and shape your voice").font(.system(size: 15)).foregroundStyle(ink.opacity(0.76))
                }
                Spacer()
            }.padding(.horizontal, 26).frame(height: 94)
            VStack(alignment: .leading, spacing: 5) {
                Text("STEP 1 · Record Voice")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(orange)
                    .padding(.leading, 36)
                HStack(spacing: 20) {
                    VStack(spacing: 5) {
                        Text(microphone.time).font(.system(size: 41, weight: .regular)).monospacedDigit()
                            .accessibilityLabel("Recorded time \(microphone.time)")
                        if microphone.state == .paused {
                            Text("Paused").font(.system(size: 11, weight: .semibold)).foregroundStyle(ink.opacity(0.7))
                        }
                    }.frame(width: 192)
                    HStack(spacing: 3) {
                        ForEach(microphone.levels.indices, id: \.self) { index in
                            Capsule().fill(Color(red: 0.53, green: 0.64, blue: 0.78))
                                .frame(width: 2.5, height: max(3, CGFloat(microphone.levels[index]) * 84))
                        }
                    }.frame(maxWidth: .infinity).frame(height: 86).accessibilityHidden(true)
                    controls.frame(width: 155)
                }.padding(.horizontal, 22).frame(height: 128)
                    .background(paleBlue, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(red: 0.77, green: 0.85, blue: 0.94)))
                    .padding(.horizontal, 25)
            }
            VStack(alignment: .center, spacing: 15) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("STEP 2 · Pick a Style")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(orange)
                    HStack(spacing: 12) {
                        ForEach(VoiceStyle.allCases) { style in
                            voiceCategory(style)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("STEP 3 · Adjust Speed")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(orange)
                        Text("?")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(red: 0.25, green: 0.48, blue: 0.73))
                            .frame(width: 15, height: 15)
                            .background(Color(red: 0.87, green: 0.93, blue: 0.99), in: Circle())
                            .onHover { showingSpeedHelp = $0 }
                            .overlay(alignment: .bottomLeading) {
                                if showingSpeedHelp {
                                    Text("The speed change applies to your modified recording.")
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundStyle(ink)
                                        .fixedSize()
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 6)
                                        .background(.white, in: RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ink.opacity(0.16)))
                                        .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                                        .offset(x: -8, y: -22)
                                        .allowsHitTesting(false)
                                }
                            }
                            .zIndex(2)
                            .accessibilityLabel("Speed help")
                            .accessibilityHint("The speed change applies to your modified recording.")
                    }
                    HStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Text("Voice Speed").font(.system(size: 15, weight: .semibold))
                            VoiceOverSpeedSlider(
                                value: Binding(
                                    get: { Double(VoiceSpeed.allCases.firstIndex(of: microphone.speed) ?? 3) },
                                    set: { index in microphone.speed = VoiceSpeed.allCases[Int(index.rounded())] }
                                ),
                                enabled: microphone.canModify && microphone.canInterruptPreview
                            )
                            .accessibilityLabel("Voice Speed")
                            .accessibilityValue(microphone.speed.label)
                            Text(microphone.speed.label)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(orange)
                                .frame(width: 38, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity)
                        Rectangle().fill(ink.opacity(0.12)).frame(width: 1, height: 38)
                        Toggle("Reduce Noise", isOn: $microphone.reduceNoise)
                            .toggleStyle(VoiceOverSwitchStyle())
                            .font(.system(size: 15, weight: .semibold))
                            .fixedSize()
                            .disabled(microphone.state == .recording || microphone.state == .paused || microphone.state == .requesting)
                            .allowsHitTesting(microphone.canInterruptPreview)
                            .help("Reduce low rumble and quiet background noise in new recordings.")
                            .frame(maxWidth: .infinity)
                    }
                    .frame(height: 60)
                    .background(paleBlue, in: RoundedRectangle(cornerRadius: 9))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 36).padding(.top, 18).padding(.bottom, 20)
            Rectangle().fill(ink.opacity(0.13)).frame(height: 1).padding(.horizontal, 25)
            HStack(spacing: 21) {
                Spacer()
                Color.clear.frame(width: 16, height: 16)
                Button("Reset") { microphone.discard() }
                    .buttonStyle(VoiceOverButton(bottomAction: true)).disabled(!microphone.canDiscard)
                    .allowsHitTesting(microphone.canInterruptPreview)
                Button(action: microphone.preview) {
                    ZStack(alignment: .leading) {
                        Text(microphone.previewActive ? "Stop Preview" : "Preview")
                            .frame(maxWidth: .infinity)
                        if microphone.previewPreparing {
                            ProgressView().controlSize(.mini).tint(orange)
                        }
                    }
                    .frame(width: 78)
                }
                    .buttonStyle(VoiceOverButton(bottomAction: true)).disabled(!microphone.canPreview)
                    .allowsHitTesting(microphone.canInterruptPreview)
                Button("Save Original") {
                    microphone.saveRecording()
                }
                .buttonStyle(VoiceOverButton(bottomAction: true)).disabled(!microphone.canSave)
                .allowsHitTesting(microphone.canInteract)
                Button("Save Modified") {
                    microphone.saveRecording(modified: true)
                }
                .buttonStyle(VoiceOverButton(filled: true, bottomAction: true)).disabled(!microphone.canSave || !microphone.isModified)
                .allowsHitTesting(microphone.canInteract)
            }.frame(height: 46).padding(.horizontal, 30).padding(.vertical, 21)
            Text("Original: M4A • Modified: WAV")
                .font(.system(size: 14)).foregroundStyle(ink.opacity(0.67))
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(paleBlue.opacity(0.55))
                .overlay(alignment: .top) { Rectangle().fill(ink.opacity(0.12)).frame(height: 1) }
        }.foregroundStyle(ink).background(.white).frame(width: 900)
            .tint(orange).preferredColorScheme(.light)
            .sheet(isPresented: Binding(
                get: { microphone.showingDiscardConfirmation },
                set: { if !$0 { microphone.resolveDiscardConfirmation(discardRecording: false) } }
            )) {
                VStack(spacing: 13) {
                    Text("Reset the Recording?")
                        .font(.system(size: 18, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("Unsaved recording will be deleted.")
                        .font(.system(size: 14))
                        .foregroundStyle(ink.opacity(0.76))
                        .frame(maxWidth: .infinity, alignment: .center)
                    HStack(spacing: 12) {
                        Button("YES") { microphone.resolveDiscardConfirmation(discardRecording: true) }
                            .buttonStyle(VoiceOverButton(compact: true))
                        Button("NO") { microphone.resolveDiscardConfirmation(discardRecording: false) }
                            .buttonStyle(VoiceOverButton(filled: true, compact: true))
                    }
                }
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(width: 360)
                .background(.white)
                .preferredColorScheme(.light)
            }
            .sheet(isPresented: Binding(
                get: { microphone.showingCloseConfirmation },
                set: { _ in }
            )) {
                VStack(spacing: 16) {
                    Text("Save this recording before close?")
                        .font(.system(size: 18, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .center)
                    HStack(spacing: 12) {
                        Button("YES") { microphone.resolveCloseConfirmation(save: true) }
                            .buttonStyle(VoiceOverButton(compact: true))
                        Button("NO") { microphone.resolveCloseConfirmation(save: false) }
                            .buttonStyle(VoiceOverButton(filled: true, compact: true))
                    }
                }
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(width: 360)
                .background(.white)
                .preferredColorScheme(.light)
            }
            .sheet(isPresented: Binding(
                get: { microphone.showingSaveSheet },
                set: { if !$0 { microphone.resolveSaveSheet(save: false) } }
            )) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(microphone.saveSheetTitle)
                        .font(.system(size: 18, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .center)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 16) {
                        GridRow {
                            Text("Save As:")
                                .font(.system(size: 14))
                                .foregroundStyle(ink.opacity(0.7))
                                .frame(width: 72, alignment: .trailing)
                            TextField("File name", text: $microphone.saveFileName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 360)
                        }
                        GridRow {
                            Text("Where:")
                                .font(.system(size: 14))
                                .foregroundStyle(ink.opacity(0.7))
                                .frame(width: 72, alignment: .trailing)
                            Menu {
                                ForEach(microphone.saveFolders, id: \.1) { folder in
                                    Button(folder.0) { microphone.saveFolder = folder.1 }
                                }
                                Divider()
                                Button("Choose Other Folder…") { microphone.chooseSaveFolder() }
                            } label: {
                                HStack {
                                    Text(microphone.saveFolder.lastPathComponent)
                                        .foregroundStyle(ink)
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(orange)
                                }
                                .padding(.horizontal, 10)
                                .frame(width: 360, height: 30)
                                .background(.white, in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(orange, lineWidth: 1))
                            }
                            .menuIndicator(.hidden)
                            .buttonStyle(.plain)
                            .fixedSize()
                        }
                    }
                    HStack(spacing: 12) {
                        Spacer()
                        Button("Cancel") { microphone.resolveSaveSheet(save: false) }
                            .buttonStyle(VoiceOverButton(compact: true))
                        Button("Save") { microphone.resolveSaveSheet(save: true) }
                            .buttonStyle(VoiceOverButton(filled: true, compact: true))
                    }
                }
                .padding(24)
                .frame(width: 520)
                .background(.white)
                .preferredColorScheme(.light)
            }
            .alert("VoiceOver", isPresented: Binding(get: { microphone.error != nil }, set: { if !$0 { microphone.error = nil } })) {
                Button("OK", role: .cancel) { microphone.error = nil }
            } message: { Text(microphone.error ?? "") }
    }

    private func voiceCategory(_ style: VoiceStyle) -> some View {
        VStack(spacing: 8) {
            Text(style.rawValue)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
            voiceChoice(style, gender: .female)
            voiceChoice(style, gender: .male)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(paleBlue, in: RoundedRectangle(cornerRadius: 9))
    }

    private func voiceChoice(_ style: VoiceStyle, gender: VoiceGender) -> some View {
        let selected = microphone.isVoiceStyleSelected(style, gender: gender)
        let sampleID = microphone.voiceSampleID(style, gender: gender)
        let playing = microphone.playingVoiceSampleID == sampleID && !microphone.voiceSamplePaused
        return Button {
            microphone.selectAndPlayVoice(style, gender: gender)
        } label: {
            HStack(spacing: 0) {
                Text(gender.rawValue)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(selected ? Color.white : Color.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle()
                    .fill(selected ? Color.white.opacity(0.45) : orange.opacity(0.45))
                    .frame(width: 1, height: 17)
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(selected ? Color.white : Color.black)
                    .frame(width: 28, height: 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .allowsHitTesting(microphone.canPlayVoiceSample)
        .accessibilityLabel("\(gender.rawValue) \(style.rawValue)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(selected ? (playing ? "Pause sample" : "Play sample") : "Select and play sample")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .frame(height: 30)
        .background(selected ? orange : Color.white, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(orange, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private var controls: some View {
        switch microphone.state {
        case .idle:
            Button(action: microphone.start) {
                Label("Start", systemImage: "record.circle").font(.system(size: 22, weight: .semibold))
                    .frame(width: 108, height: 12)
            }
            .buttonStyle(VoiceOverButton(filled: true))
            .focusable(false)
            .disabled(microphone.busy)
        case .requesting:
            ProgressView().controlSize(.small).accessibilityLabel("Requesting microphone permission")
        case .recording, .paused:
            VStack(spacing: 8) {
                Button(action: microphone.pauseOrResume) {
                    Label(microphone.state == .paused ? "Resume" : "Pause", systemImage: microphone.state == .paused ? "play.fill" : "pause.fill")
                        .frame(width: 128)
                }.buttonStyle(VoiceOverButton(compact: true))
                Button { microphone.stop() } label: {
                    Label("Stop", systemImage: "stop.fill").frame(width: 128)
                }.buttonStyle(VoiceOverButton(filled: true, compact: true))
            }.disabled(microphone.busy)
        case .stopped:
            if microphone.previewActive {
                VStack(spacing: 8) {
                    Text("Playing Preview")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(ink.opacity(0.72))
                    Button(action: microphone.pauseOrResumePreview) {
                        Label(microphone.previewPaused ? "Resume" : "Pause", systemImage: microphone.previewPaused ? "play.fill" : "pause.fill")
                            .frame(width: 128)
                    }
                    .buttonStyle(VoiceOverButton(compact: true))
                    .disabled(microphone.busy)
                    Button(action: microphone.stopPreview) {
                        Label("Stop", systemImage: "stop.fill").frame(width: 128)
                    }
                    .buttonStyle(VoiceOverButton(filled: true, compact: true))
                }
            } else {
                Label("Stopped", systemImage: "stop.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(ink.opacity(0.65))
            }
        }
    }
}
