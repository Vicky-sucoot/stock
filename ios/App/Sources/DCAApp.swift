import DCAKit
import SwiftUI

@main
struct DCAApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environment(\.locale, Locale(identifier: "zh_Hant_TW"))
        }
        .onChange(of: scenePhase) { _, newPhase in model.scenePhaseChanged(newPhase) }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch model.phase {
            case .onboarding: OnboardingFlow()
            case .locked: LockScreen()
            case .unlocked: MainTabs()
            }
            // 切換 App 時遮住畫面，避免在多工畫面露出資產（docs/10 §4）
            if scenePhase != .active && model.phase == .unlocked {
                PrivacyCover()
            }
        }
        .alert("無法完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.largeTitle)
                Text("定期定額").font(.headline)
            }
            .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("首頁", systemImage: "house") }
            NavigationStack { PortfolioListView() }
                .tabItem { Label("組合", systemImage: "folder") }
            NavigationStack { WatchlistPlaceholderView() }
                .tabItem { Label("觀察", systemImage: "eye") }
            NavigationStack { SettingsView() }
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
    }
}

/// 每日觀察名單在第五階段實作（docs/06）。
struct WatchlistPlaceholderView: View {
    var body: some View {
        ContentUnavailableView {
            Label("每日觀察名單", systemImage: "eye")
        } description: {
            Text("尚未開放。後端正在累積上櫃外資資料與公司重大訊息；評分規則完成並通過驗證後才會顯示。")
        }
        .navigationTitle("觀察")
    }
}
