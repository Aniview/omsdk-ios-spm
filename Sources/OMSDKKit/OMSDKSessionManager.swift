//
//  OMSDKSessionManager.swift
//  OMSDKKit
//
//  Ergonomic Swift wrapper around OMSDK for WebView-hosted video ads.
//  Native owns firing AdEvents/MediaEvents since the host app already knows every playback/impression event.
//
//  Reference: https://interactiveadvertisingbureau.github.io/Open-Measurement-SDKiOS/#webview-video
//

import WebKit
import OMSDK_Aniview
import os

/// Ad position for the VAST `loaded` event — a neutral mirror of OM SDK's own
/// `OMIDPosition` so consumers of this package don't need to import OMSDK's build
/// themselves just to call `signalLoaded`.
public enum OMSDKAdPosition {
    case preroll
    case midroll
    case postroll
    case standalone
}

/// Friendly-obstruction purpose — a neutral mirror of OM SDK's own
/// `OMIDFriendlyObstructionType`, same reasoning as `OMSDKAdPosition`.
public enum OMSDKFriendlyObstructionPurpose {
    case mediaControls
    case closeAd
    case notVisible
    case other
}

public final class OMSDKSessionManager {

    private static let logger = Logger(subsystem: "com.aniview.omsdkkit", category: "OMSDKSessionManager")

    // MARK: - Activate the SDK once, at app/SDK bootstrap
    public static func activate() {
        let didActivate = OMIDAniviewSDK.shared.activate()
        if !didActivate {
            logger.error("OMSDK: activation failed")
        }
    }

    // MARK: - Inject the OMID JS library into the ad HTML shell, before it's loaded
    public static func injectOMIDScript(_ omidJS: String, intoHTML html: String) -> String {
        do {
            return try OMIDAniviewScriptInjector.injectScriptContent(omidJS, intoHTML: html)
        } catch {
            logger.error("OMSDK: script injection failed: \(String(describing: error))")
            return html
        }
    }

    private let partnerName: String
    private let partnerVersion: String

    private var session: OMIDAniviewAdSession?
    private var adEvents: OMIDAniviewAdEvents?
    private var mediaEvents: OMIDAniviewMediaEvents?

    // per-session guards so re-firing an event from a chatty caller stays a no-op
    private var impressionFired = false
    private var hasStartedPlayback = false
    private var isPaused = false
    private var firedFirstQuartile = false
    private var firedMidpoint = false
    private var firedThirdQuartile = false

    private var lastKnownDuration: TimeInterval = 0
    private var lastKnownVolume: Float = 1

    public init(partnerName: String, partnerVersion: String) {
        self.partnerName = partnerName
        self.partnerVersion = partnerVersion
    }

    // MARK: - Create, configure, and start the session
    // Call once the WebView's own JS/ad bridge is confirmed ready — this is the "WebView
    // loaded" checkpoint the doc requires before session creation. Always pair with
    // `finish(webView:)` when the current ad ends, since one session = one ad impression.
    public func start(webView: WKWebView, contentUrl: String? = nil, isolateVerificationScripts: Bool = false) {
        guard session == nil else {
            Self.logger.debug("OMSDK: session already active, call finish() before starting a new one")
            return
        }

        // initializer is failable, not throwing.
        guard let partner = OMIDAniviewPartner(name: partnerName, versionString: partnerVersion) else {
            Self.logger.error("OMSDK: failed to create partner (\(self.partnerName) / \(self.partnerVersion))")
            return
        }

        do {
            // WebView-hosted creative, "html" session type — matches IAB's WebViewVideoController sample.
            let context = try OMIDAniviewAdSessionContext(
                partner: partner,
                webView: webView,
                contentUrl: contentUrl,
                customReferenceIdentifier: nil
            )

            // Native owns both impression and media events.
            let config = try OMIDAniviewAdSessionConfiguration(
                creativeType: .video,
                impressionType: .beginToRender,
                impressionOwner: .nativeOwner,
                mediaEventsOwner: .nativeOwner,
                isolateVerificationScripts: isolateVerificationScripts
            )

            let newSession = try OMIDAniviewAdSession(configuration: config, adSessionContext: context)
            newSession.mainAdView = webView

            session = newSession
            adEvents = try OMIDAniviewAdEvents(adSession: newSession)
            mediaEvents = try OMIDAniviewMediaEvents(adSession: newSession)

            newSession.start() // must happen before any AdEvents/MediaEvents are dispatched
        } catch {
            Self.logger.error("OMSDK: session setup failed: \(String(describing: error))")
        }
    }

    // MARK: Friendly obstructions (close button, skip button, captions, etc.)
    public func addFriendlyObstruction(_ view: UIView, purpose: OMSDKFriendlyObstructionPurpose, detailedReason: String?) {
        do {
            try session?.addFriendlyObstruction(view, purpose: mapPurpose(purpose), detailedReason: detailedReason)
        } catch {
            Self.logger.error("OMSDK: addFriendlyObstruction failed: \(String(describing: error))")
        }
    }

    public func removeFriendlyObstruction(_ view: UIView) {
        session?.removeFriendlyObstruction(view)
    }

    public func removeAllFriendlyObstructions() {
        session?.removeAllFriendlyObstructions()
    }

    private func mapPurpose(_ purpose: OMSDKFriendlyObstructionPurpose) -> OMIDFriendlyObstructionType {
        switch purpose {
        case .mediaControls: .mediaControls
        case .closeAd: .closeAd
        case .notVisible: .notVisible
        case .other: .other
        }
    }

    // MARK: - Ad load event
    // skipOffset nil = not skippable (matches OMIDVASTProperties' two separate
    // initializers — there's no single init taking an explicit isSkippable flag).
    public func signalLoaded(skipOffset: TimeInterval?, isAutoPlay: Bool, position: OMSDKAdPosition) {
        let omidPosition = mapPosition(position)
        let vastProperties: OMIDAniviewVASTProperties
        if let skipOffset {
            vastProperties = OMIDAniviewVASTProperties(
                skipOffset: skipOffset,
                autoPlay: isAutoPlay,
                position: omidPosition
            )
        } else {
            vastProperties = OMIDAniviewVASTProperties(autoPlay: isAutoPlay, position: omidPosition)
        }

        do {
            try adEvents?.loaded(with: vastProperties)
        } catch {
            Self.logger.error("OMSDK: loaded event failed: \(String(describing: error))")
        }
    }

    private func mapPosition(_ position: OMSDKAdPosition) -> OMIDPosition {
        switch position {
        case .preroll: .preroll
        case .midroll: .midroll
        case .postroll: .postroll
        case .standalone: .standalone
        }
    }

    // MARK: - Impression (fires on first frame render)
    public func signalImpression() {
        guard !impressionFired else { return }
        impressionFired = true
        do {
            try adEvents?.impressionOccurred()
        } catch {
            Self.logger.error("OMSDK: impressionOccurred failed: \(String(describing: error))")
        }
    }

    // Cache duration/volume as they arrive so `start` has real values whenever it fires
    public func updateDuration(_ duration: TimeInterval) {
        lastKnownDuration = duration
    }

    public func updateVolume(_ volume: Float) {
        lastKnownVolume = volume
        mediaEvents?.volumeChange(to: CGFloat(volume))
    }

    // MARK: - Playback progress events
    // Routes both "first playback" and "resume after pause" through one call, since a
    public func notifyPlaying() {
        if !hasStartedPlayback {
            hasStartedPlayback = true
            mediaEvents?.start(withDuration: lastKnownDuration, mediaPlayerVolume: CGFloat(lastKnownVolume))
        } else if isPaused {
            isPaused = false
            mediaEvents?.resume()
        }
        // already playing, ignore the duplicate "playing" signal
    }

    public func notifyPaused() {
        guard hasStartedPlayback, !isPaused else { return }
        isPaused = true
        mediaEvents?.pause()
    }

    public func signalFirstQuartile() {
        guard !firedFirstQuartile else { return }
        firedFirstQuartile = true
        mediaEvents?.firstQuartile()
    }

    public func signalMidpoint() {
        guard !firedMidpoint else { return }
        firedMidpoint = true
        mediaEvents?.midpoint()
    }

    public func signalThirdQuartile() {
        guard !firedThirdQuartile else { return }
        firedThirdQuartile = true
        mediaEvents?.thirdQuartile()
    }

    public func signalComplete() {
        mediaEvents?.complete()
    }

    public func signalSkipped() {
        mediaEvents?.skipped()
    }

    public func signalBufferStart() {
        mediaEvents?.bufferStart()
    }

    public func signalBufferFinish() {
        mediaEvents?.bufferFinish()
    }

    public func signalFullscreenStateChanged(isFullscreen: Bool) {
        mediaEvents?.playerStateChange(to: isFullscreen ? .fullscreen : .normal)
    }

    // MARK: - Stop the session on ad completion / skip / error / early close.
    // Retains the WebView ~1s afterward so verification scripts have time to receive
    // `sessionFinish` before the view can be torn down.
    public func finish(webView: WKWebView?) {
        guard session != nil else { return }

        session?.finish()
        session = nil
        adEvents = nil
        mediaEvents = nil

        impressionFired = false
        hasStartedPlayback = false
        isPaused = false
        firedFirstQuartile = false
        firedMidpoint = false
        firedThirdQuartile = false

        let retainedWebView = webView
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            _ = retainedWebView // no-op; just extends the retain window
        }
    }
}
