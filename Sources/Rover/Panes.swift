// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import AppKit
import SwiftUI
import Quartz
import RoverCore

/// Live Quick Look preview of the selected file, with its location and quick actions.
struct PreviewPane: View {
    let hit: Hit?
    @ObservedObject var model: SearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let h = hit {
                QLView(path: h.path).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.03))
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 6) {
                    Text(h.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).truncationMode(.middle)
                    Button(action: { model.reveal() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder").font(.system(size: 10))
                            Text(Fmt.folder(h.path)).lineLimit(1).truncationMode(.head)
                        }
                        .font(.system(size: 11)).foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain).help("Show in Finder (⌘↩)")
                    HStack(spacing: 10) {
                        Text(h.kind.label)
                        if !Fmt.size(h).isEmpty { Text(Fmt.size(h)) }
                        Text("Modified " + Fmt.date(h.mtime))
                    }
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        PaneButton(title: "Open", icon: "arrow.up.forward.app") { model.open() }
                        PaneButton(title: "Show in Finder", icon: "folder") { model.reveal() }
                        PaneButton(title: "Move…", icon: "arrow.right.doc.on.clipboard") { model.startMove() }
                    }
                    .padding(.top, 2)
                }
                .padding(12)
            } else {
                Spacer()
                Text("No selection").foregroundColor(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }
}

struct PaneButton: View {
    let title: String, icon: String, action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

struct QLView: NSViewRepresentable {
    let path: String
    final class Coordinator { var path = ""; var work: DispatchWorkItem? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .compact)!
        v.shouldCloseWithWindow = false
        v.autostarts = true
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) {
        guard context.coordinator.path != path else { return }
        context.coordinator.path = path
        // debounce while arrowing quickly through results
        context.coordinator.work?.cancel()
        let p = path
        let w = DispatchWorkItem { v.previewItem = URL(fileURLWithPath: p) as NSURL }
        context.coordinator.work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: w)
    }
    static func dismantleNSView(_ v: QLPreviewView, coordinator: Coordinator) { v.close() }
}

/// Assistant conversation: answers, files it found, and change plans to approve.
struct AskView: View {
    @ObservedObject var model: SearchModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.turns.isEmpty { intro }
                    ForEach(Array(model.turns.enumerated()), id: \.element.id) { ti, t in
                        TurnView(turn: t, isLast: ti == model.turns.count - 1, model: model).id(t.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
            }
            .onChange(of: model.turns.last?.answer) { _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.turns.count) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask Rover").font(.system(size: 15, weight: .semibold))
            Text("It searches names and contents, reads documents and photos, and can move, rename or tidy files and set up automations. You approve every change, and ⌘Z undoes it.")
                .font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(["Which PDF has my lease renewal date?", "Find the photo of my passport",
                     "Sort my Downloads into folders by type", "From now on, move screenshots off my Desktop into Pictures/Screenshots"], id: \.self) { ex in
                Button(action: { model.text = ex; model.commit() }) {
                    Text(ex).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                }.buttonStyle(.plain)
            }
            Text("Uses \(Assistant.backendName).").font(.system(size: 10.5)).foregroundColor(.secondary.opacity(0.8))
        }
    }
}

struct TurnView: View {
    let turn: Turn
    let isLast: Bool
    @ObservedObject var model: SearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.question).font(.system(size: 13, weight: .semibold))
            if !turn.answer.isEmpty {
                Text(markdown(turn.answer)).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if turn.running && !turn.status.isEmpty || turn.running && turn.answer.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(turn.status.isEmpty ? "Thinking…" : turn.status).font(.system(size: 11.5)).foregroundColor(.secondary)
                }
            }
            if !turn.files.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(turn.files.enumerated()), id: \.element.id) { i, h in
                        Row(hit: h, selected: isLast && i == model.askSelected, index: i)
                            .contentShape(Rectangle())
                            .gesture(TapGesture(count: 2).onEnded { model.select(i); model.open() })
                            .simultaneousGesture(TapGesture().onEnded { if isLast { model.select(i) } })
                            .onDrag { NSItemProvider(object: URL(fileURLWithPath: h.path) as NSURL) }
                    }
                }
            }
            if let p = turn.proposal { ProposalCard(p: p, state: turn.proposalState, live: isLast && turn.proposalState == 0, model: model) }
            if let e = turn.error {
                Label(e, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct ProposalCard: View {
    let p: Assistant.Proposal
    let state: Int
    let live: Bool
    @ObservedObject var model: SearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: p.rule != nil ? "bolt.badge.clock" : "arrow.triangle.branch")
                Text(p.summary).font(.system(size: 12.5, weight: .semibold))
            }
            if let r = p.rule {
                Text(r.summary).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Text("Runs automatically from now on. Turn it off any time from the menu bar icon.").font(.system(size: 11)).foregroundColor(.secondary)
            }
            if !p.actions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(p.actions.prefix(40)) { a in
                        Text("• " + a.summary).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                    }
                    if p.actions.count > 40 { Text("…and \(p.actions.count - 40) more").font(.system(size: 11.5)).foregroundColor(.secondary) }
                }
            }
            ForEach(p.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundColor(.orange) }
            HStack(spacing: 8) {
                switch state {
                case 0:
                    Button(action: { model.approve(true) }) {
                        Text(p.actions.isEmpty ? "Turn on" : "Do it (\(p.actions.count))").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor)).foregroundColor(.white)
                    }.buttonStyle(.plain).disabled(!live)
                    Button(action: { model.approve(false) }) {
                        Text("Don't").font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.15)))
                    }.buttonStyle(.plain).disabled(!live)
                    if live { Text("⌘↩").font(.system(size: 10)).foregroundColor(.secondary) }
                case 1:
                    Label("Done", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(.green)
                    if !p.actions.isEmpty {
                        Button("Undo") { model.undo() }.buttonStyle(.link).font(.system(size: 12))
                    }
                default:
                    Label("Skipped — nothing changed", systemImage: "xmark.circle").font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.25)))
    }
}
