import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class UsageModel: ObservableObject {
    @Published var menuTitle = "Cursor"
    @Published var snapshot: UsageSnapshot?
    @Published var errorMessage: String?
    @Published var isRefreshing = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var loop: Task<Void, Never>?

    func start() {
        if let cached = UsageCache.load() {
            snapshot = cached
            menuTitle = UsageText.menuTitle(cached)
        }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                let pause = self?.nextPause() ?? 180
                try? await Task.sleep(for: .seconds(pause))
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await CursorSession.snapshot()
            snapshot = fresh
            errorMessage = nil
            menuTitle = UsageText.menuTitle(fresh)
            UsageCache.save(fresh)
        } catch {
            errorMessage = UsageText.message(for: error)
            if snapshot == nil {
                menuTitle = "Cursor"
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorMessage = "Автозапуск не включился"
        }
    }

    private func nextPause() -> Double {
        guard let reset = snapshot?.grokReset else { return 180 }
        let remaining = reset.timeIntervalSinceNow
        if remaining < 15 * 60 { return 60 }
        return 180
    }
}

@main
struct CursorUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            UsagePanel()
        } label: {
            MenuTitle()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            exit(UsageSelfTest.run() ? 0 : 1)
        }
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            UsageStore.shared.start()
        }
    }
}

private struct MenuTitle: View {
    @ObservedObject private var model = UsageStore.shared

    var body: some View {
        Text(model.menuTitle)
            .font(.system(size: 13, weight: .medium, design: .rounded))
    }
}

@MainActor
enum UsageStore {
    static let shared = UsageModel()
}

private struct UsagePanel: View {
    @ObservedObject private var model = UsageStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Входит в состав \(model.snapshot?.planLabel ?? "Cursor")")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                meter(
                    title: "Модели курсоров",
                    subtitle: "Включает Cursor Grok и Composer",
                    percent: model.snapshot?.cursorModelsPercent,
                    trailing: usedFirst(model.snapshot?.cursorModelsPercent),
                    footnote: "Дополнительное использование сверх лимита расходует квоту других моделей."
                )
                Divider()
                meter(
                    title: "Другие модели",
                    subtitle: nil,
                    percent: model.snapshot?.otherModelsPercent,
                    trailing: usedSecond(model.snapshot?.otherModelsPercent),
                    footnote: "Дополнительное использование сверх лимита расходует средства по требованию."
                )
            }
            .padding(14)
            .background(card)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Грок Бот")
                        .font(.headline)
                    Text("Входит в состав \(model.snapshot?.planLabel ?? "Cursor")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                meter(
                    title: "Еженедельное использование",
                    subtitle: nil,
                    percent: model.snapshot?.grokPercent,
                    trailing: usedSecond(model.snapshot?.grokPercent),
                    footnote: model.snapshot?.grokUnavailableReason
                        ?? "Грок Бот останавливается на лимите, пока счётчик не сбросится."
                )
                if let reset = model.snapshot?.grokReset {
                    Text(UsageText.resetLine(at: reset))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(14)
            .background(card)

            footer
        }
        .padding(16)
        .frame(width: 460)
        .onAppear { model.start() }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.045))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let fetchedAt = model.snapshot?.fetchedAt {
                    Text(updated(fetchedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button("Обновить") {
                    Task { await model.refresh() }
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing)
            }
            HStack {
                Toggle("Открывать при входе", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                Spacer()
                Button("Завершить") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    private func meter(
        title: String,
        subtitle: String?,
        percent: Double?,
        trailing: String,
        footnote: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            UsageBar(percent: percent)
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func usedFirst(_ value: Double?) -> String {
        guard let value else { return "нет данных" }
        return "использовано \(UsageText.percent(value))"
    }

    private func usedSecond(_ value: Double?) -> String {
        guard let value else { return "нет данных" }
        return "\(UsageText.percent(value)) использовано"
    }

    private func updated(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return "Обновлено в \(formatter.string(from: date))"
    }
}

private struct UsageBar: View {
    let percent: Double?

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max((percent ?? 0) / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(fill)
                    .frame(width: fraction == 0 ? 0 : max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 7)
        .accessibilityLabel(percent.map { "\(Int($0.rounded())) процентов" } ?? "нет данных")
    }

    private var fill: Color {
        let value = percent ?? 0
        if value >= 95 { return Color(red: 0.86, green: 0.25, blue: 0.22) }
        if value >= 80 { return Color(red: 0.92, green: 0.55, blue: 0.16) }
        return Color(red: 0.29, green: 0.52, blue: 0.93)
    }
}
