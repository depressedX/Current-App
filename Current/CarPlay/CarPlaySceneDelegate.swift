import CarPlay
import Combine

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    private var controller: CPInterfaceController?
    private var queueTemplate: CPListTemplate?
    private var historyTemplate: CPListTemplate?
    private var subscriptions = Set<AnyCancellable>()
    private var store: AppStore { .shared }
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        controller = interfaceController
        let queue = CPListTemplate(title: "此刻队列", sections: [])
        queue.tabImage = UIImage(systemName: "music.note.list")
        queue.emptyViewTitleVariants = ["在 iPhone 写下此刻想听的音乐"]
        queueTemplate = queue
        let history = CPListTemplate(title: "最近的此刻", sections: [])
        history.tabImage = UIImage(systemName: "clock")
        history.emptyViewTitleVariants = ["先在 iPhone 准备一个队列"]
        historyTemplate = history
        let root = CPTabBarTemplate(templates: [queue, history])
        interfaceController.setRootTemplate(root, animated: false, completion: nil)
        CPNowPlayingTemplate.shared.add(self)
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled = true
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([
            CPNowPlayingImageButton(image: UIImage(systemName: "heart")!) { [weak self] _ in
                guard let self, let song = self.store.currentTrack else { return }
                self.store.record(.fits, track: song)
            }
        ])
        store.$queue.combineLatest(store.$currentIndex).sink { [weak self] _, _ in
            Task { @MainActor in self?.refreshQueue() }
        }.store(in: &subscriptions)
        store.$queueEnded.combineLatest(store.$recommendationExhausted).sink { [weak self] _, _ in
            Task { @MainActor in self?.refreshQueue() }
        }.store(in: &subscriptions)
        store.$sessions.combineLatest(store.$listener).sink { [weak self] _, _ in
            Task { @MainActor in self?.refreshHistory() }
        }.store(in: &subscriptions)
        refreshQueue(); refreshHistory()
        Task { await store.restoreSession() }
    }
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        CPNowPlayingTemplate.shared.remove(self)
        subscriptions.removeAll(); controller = nil; queueTemplate = nil; historyTemplate = nil
    }
    private func refreshQueue() {
        var items = store.queue.enumerated().map { index, song in
            let item = CPListItem(text: song.title, detailText: song.artist)
            item.isPlaying = store.currentIndex == index
            item.handler = { [weak self] _, completion in
                guard let self else { completion(); return }
                self.store.play(at: index)
                self.controller?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                completion()
            }
            return item
        }
        if store.queueEnded && store.recommendationExhausted {
            let more = CPListItem(text: "允许重复继续听", detailText: "本轮候选已听完，延续当前听感")
            more.handler = { [weak self] _, completion in
                self?.store.continueWithRepeats()
                completion()
            }
            items.append(more)
        }
        queueTemplate?.updateSections([CPListSection(items: items)])
    }
    private func refreshHistory() {
        let items = store.visibleSessions.prefix(8).map { session in
            let item = CPListItem(text: session.prompt, detailText: "\(session.tracks.count) 首 · \(session.listenerID == nil ? "演示音频" : "网易云音乐")")
            item.handler = { [weak self] _, completion in
                self?.store.replay(session)
                self?.controller?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
                completion()
            }
            return item
        }
        historyTemplate?.updateSections([CPListSection(items: items)])
    }
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in
            guard let queue = self.queueTemplate else { return }
            self.controller?.popToRootTemplate(animated: true, completion: nil)
            // The queue is the first tab; do not push a template already owned by the tab bar.
            if let root = self.controller?.rootTemplate as? CPTabBarTemplate { root.select(queue) }
        }
    }
}
