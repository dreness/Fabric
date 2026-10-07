//
//  ContentView.swift
//  Fabric
//
//  Created by Anton Marini on 4/24/25.
//

import SwiftUI
import Fabric

struct ContentView: View {

    @Binding var document: FabricDocument
    let documentURL: URL?
    @Environment(\.undoManager) private var undoManager

    @State private var canvasHitTestingEnabled = true
    
    @State private var radialGradientEndRadius: CGFloat = .zero

    @State private var canvasScrollPosition = ScrollPosition()

    @State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn
    @State private var inspectorVisibility:Bool = true

    // Seeded in onAppear once the document's AppKit-side output hosting
    // exists; the document itself is not observable, this is.
    @State private var outputPresenter: OutputPresenter?

    // The editor's single keyboard-focus authority. SwiftUI writes it on every
    // real focus change (canvas, registry search/list — or nil when e.g. a node
    // settings text field has focus), and views/menu commands read or set it to
    // route and move focus. Never shadow it with plain @State.
    @FocusState private var focusTarget: FabricEditorFocusTarget?

    init(document: Binding<FabricDocument>, documentURL: URL? = nil) {
        self._document = document
        self.documentURL = documentURL
    }

    // Magic Numbers...
    private let canvasSize = 10000.0
    
    var body: some View {

        NavigationSplitView(columnVisibility: self.$columnVisibility)
        {
            NodeRegisitryView(graphRenderer:self.document.renderer,
                              editingContext: self.document.editingContext,
                              focus: self.$focusTarget)
                .navigationSplitViewColumnWidth(min: 150, ideal: 200, max:250)

        } detail: {
            VStack(alignment: .leading, spacing:0)
            {
                Divider()

                Spacer()

                HStack(spacing:5)
                {
                    Button("Root Graph", action: self.document.editingContext.popToRoot)
                        .font(.headline)
                        .buttonStyle(.plain)

                    ForEach(self.document.editingContext.entries) { node in
                        Text("›")
                            .font(.headline)
                        Button(node.title) { self.document.editingContext.popTo(node) }
                            .font(.headline)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)

                Spacer()

                Divider()

                ZStack
                {
                    CanvasBackdropView(outputPresenter: self.outputPresenter,
                                       radialGradientEndRadius: self.radialGradientEndRadius)

                    ScrollViewReader { proxy in
                        ScrollView([.horizontal, .vertical])
                        {
                            GraphCanvas(editingContext: self.document.editingContext,
                                        focus: self.$focusTarget,
                                        canvasSize: CGSize(width: self.canvasSize, height: self.canvasSize),
                                        connectionsHitTestingEnabled: self.canvasHitTestingEnabled)
                                .id("canvas")
                                .frame(width: self.canvasSize, height: self.canvasSize)
                                .modifier(GraphCanvasZoomModifier(
                                    editingContext: self.document.editingContext,
                                    canvasSize: CGSize(width: self.canvasSize, height: self.canvasSize),
                                    scrollPosition: self.$canvasScrollPosition,
                                    allowsContentHitTesting: self.canvasHitTestingEnabled
                                ))
                                .contextMenu(menuItems: {
                                    Button("New Note") {
                                        let editingContext = self.document.editingContext
                                        let noteSize = CGSize(width: 500, height: 500)
                                        let note = Note(note: "New Note",
                                                        rect: CGRect(origin: editingContext.visibleGraphCenter - noteSize / 2,
                                                                     size: noteSize))
                                        editingContext.currentGraph.addNote(note)
                                    }
                                })
                                .onAppear {
                                    self.document.editingContext.rootGraph.undoManager = undoManager

                                    DispatchQueue.main.asyncAfter(deadline: .now().advanced(by: .milliseconds(10)) ) {
                                        let editingContext = self.document.editingContext
                                        if let firstNode = editingContext.rootGraph.nodes.first
                                        {
                                            let canvasPosition = editingContext.canvasPosition(forGraphPosition: CGPoint(x: firstNode.offset.width,
                                                                                                                         y: firstNode.offset.height))
                                            let targetPoint = UnitPoint(x: canvasPosition.x / self.canvasSize,
                                                                        y: canvasPosition.y / self.canvasSize)
                                            proxy.scrollTo("canvas", anchor: targetPoint)
                                        }
                                    }
                                }

                        }
                        .defaultScrollAnchor(.center)
                        .scrollPosition(self.$canvasScrollPosition)
                        .onScrollPhaseChange { _, newPhase in
                            self.canvasHitTestingEnabled = !newPhase.isScrolling
                        }
                    }
                    .onScrollGeometryChange(for: ScrollGeometry.self) { geometry in
                        geometry
                    } action: { _, newGeometry in
                        self.document.editingContext.currentScrollGeometry = newGeometry

                        let newRadialGradientEndRadius = newGeometry.containerSize.width * 1.5
                        if self.radialGradientEndRadius != newRadialGradientEndRadius
                        {
                            self.radialGradientEndRadius = newRadialGradientEndRadius
                        }
                    }
                }
            }
            .inspector(isPresented: self.$inspectorVisibility)
            {
                NodeSelectionInspector(editingContext: self.document.editingContext)
                    .inspectorColumnWidth(min:250, ideal:250, max:300)
            }
            // Menu commands read and steer real focus through this binding —
            // e.g. "is the canvas focused?" for Copy/Paste routing, and
            // Find Nodes writing .registrySearch to focus the search field.
            .focusedSceneValue(\.editorFocusTarget, Binding(
                get: { self.focusTarget },
                set: { self.focusTarget = $0 }
            ))
            .sheet(
                isPresented: Binding(
                    get: {
                        self.document.movieExportCoordinator.isPresented
                    },
                    set: { isPresented in
                        if !isPresented {
                            self.document.dismissMovieExportSheet()
                        }
                    }
                )
            ) {
                MovieExportSheetView(
                    coordinator: self.document.movieExportCoordinator,
                    onDismiss: {
                        self.document.dismissMovieExportSheet()
                    },
                    onContinue: { configuration in
                        self.document.continueMovieExport(with: configuration)
                    }
                )
            }
            .toolbar
            {
                if let outputPresenter = self.outputPresenter, OutputSettings.shared.mode == .editorCanvas
                {
                    ToolbarItem(placement: .automatic)
                    {
                        OutputPlaybackToolbarButton(presenter: outputPresenter)
                    }
                }

                ToolbarItem(placement: .automatic)
                {
                    Button("Parameters", systemImage: "sidebar.right") {
                        self.inspectorVisibility.toggle()
                    }
                }
            }
            .onAppear {
                // AppKit window creation has to happen on the main thread
                // once the scene is up; onAppear guarantees both.
                self.document.updateDocumentURL(self.documentURL)
                self.document.setupOutputPresentation()
                self.outputPresenter = self.document.outputPresenter
            }
            .onChange(of: self.documentURL) { _, newDocumentURL in
                self.document.updateDocumentURL(newDocumentURL)
            }
            .onDisappear {
                self.outputPresenter = nil
                self.document.teardownOutputPresentation()
            }
            .background(ActiveDocumentTracker(document: self.document))
        }
    }
}

/// Keeps `ActiveFabricDocumentStore` pointed at the document whose editor
/// window is key. The output window's `windowDidBecomeMain` also does this,
/// but in editor-canvas mode no output window exists. A separate struct so
/// window-focus changes invalidate this view, not the whole editor.
struct ActiveDocumentTracker: View {
    let document: FabricDocument
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Color.clear
            .onChange(of: self.controlActiveState) { _, newState in
                guard newState == .key else { return }
                ActiveFabricDocumentStore.shared.activeDocument = self.document
            }
    }
}

/// Reading playback state here rather than in `ContentView.body` keeps a
/// play/pause toggle from re-evaluating the whole editor.
struct OutputPlaybackToolbarButton: View {
    let presenter: OutputPresenter

    var body: some View {
        Button(self.presenter.playbackControlLabel,
               systemImage: self.presenter.playbackControlSymbolName)
        {
            self.presenter.togglePlayback()
        }
    }
}

/// The node canvas background: live rendered output when the presenter is in
/// editor-canvas mode, otherwise the decorative gradient.
struct CanvasBackdropView: View {
    let outputPresenter: OutputPresenter?
    let radialGradientEndRadius: CGFloat

    var body: some View {
        if let outputPresenter, OutputSettings.shared.mode == .editorCanvas
        {
            OutputCanvasHostView(presenter: outputPresenter)
                .allowsHitTesting(false)
        }
        else
        {
            RadialGradient(colors: [.clear, .black.opacity(0.75)], center: .center, startRadius: 0, endRadius: self.radialGradientEndRadius)
        }
    }
}

#Preview {
    ContentView(document: .constant(FabricDocument()))
}
