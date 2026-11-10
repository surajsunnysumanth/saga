import SwiftUI
import Charts
import SagaCore

struct PeopleSidebar: View {
    @Environment(AppModel.self) var model
    var body: some View {
        @Bindable var m = model
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find a person", text: $m.peopleQuery).textFieldStyle(.plain)
                    }.padding(.horizontal, 8).padding(.vertical, 6).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
                    Menu {
                        Picker("Sort by", selection: $m.peopleSort) { ForEach(PersonSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        Divider()
                        Toggle("Only people with a contact name", isOn: $m.peopleNamedOnly)
                    } label: { Image(systemName: "arrow.up.arrow.down") }.menuStyle(.borderlessButton).fixedSize()
                }
                HStack {
                    Text("\(model.people.count.formatted()) people").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.peopleSort.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: AppTheme.Spacing.xxs) {
                    sidebarEntry(title: "Merge contacts", symbol: "person.2.badge.gearshape", badge: nil,
                                 help: "Two numbers that are one person, shown with the evidence before anything changes") {
                        model.openMergeContacts()
                    }
                    sidebarEntry(title: "Chats without a name", symbol: "questionmark.circle", badge: model.unnamedTotal,
                                 help: "Every chat the archive could not name — read it, name the ones that are people") {
                        model.openUnnamedChats()
                    }
                }
            }.padding([.horizontal, .top], 10).padding(.bottom, 6)
            Divider()
            if model.people.isEmpty {
                EmptyStateView(
                    symbol: model.peopleQuery.isEmpty ? "person.2" : "magnifyingglass",
                    title: model.peopleQuery.isEmpty ? "No people yet" : "No one matches “\(model.peopleQuery)”",
                    message: model.peopleQuery.isEmpty
                        ? "People appear here once your archive has messages from them."
                        : (model.peopleNamedOnly
                           ? "Try fewer letters, or include people without a saved contact name."
                           : "Try a shorter name or a phone number."),
                    colors: AppTheme.Module.people.colors,
                    actionTitle: model.peopleQuery.isEmpty ? nil : (model.peopleNamedOnly ? "Include unnamed people" : "Clear the search"),
                    action: model.peopleQuery.isEmpty ? nil : {
                        if model.peopleNamedOnly { model.peopleNamedOnly = false } else { model.peopleQuery = "" }
                    },
                    compact: true)
            } else {
                List(selection: Binding(get: { model.selectedPerson?.id }, set: { id in
                    if let id, let p = model.people.first(where: { $0.id == id }) { model.selectedPerson = p }
                })) {
                    ForEach(model.people) { p in
                        HStack(spacing: 10) {
                            Avatar(name: p.name, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                Text("\(p.received.formatted()) messages · last \(p.last.listLabel)").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 3).tag(p.id)
                    }
                }.listStyle(.sidebar)
            }
        }.navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
        // The sheet is presented from the view that owns the row, so it is a host of its own instead of
        // one of seven `.sheet` modifiers stacked on ContentView — where macOS silently dropped it and a
        // click looked like nothing at all.
        .sheet(isPresented: Binding(get: { model.showUnnamed }, set: { model.showUnnamed = $0 })) {
            UnnamedChatsView().environment(model)
        }
    }

    /// The two doors to the address book's loose ends: a number that is really a person you
    /// already know, and everyone the archive could not name. They sit with the People list
    /// because that is where the question "who is this?" is asked, and the unnamed row carries
    /// its count so the number is visible without opening a menu.
    private func sidebarEntry(title: String, symbol: String, badge: Int?, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AppTheme.Accent.text)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: AppTheme.Spacing.xxs)
                if let badge, badge > 0 {
                    Text(badge.formatted())
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppTheme.Surface.textTertiary)
            }
            .padding(.horizontal, AppTheme.Spacing.s)
            .frame(height: 30)
            .background(AppTheme.Radius.controlShape.fill(AppTheme.Surface.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct PersonDetailView: View {
    @Environment(AppModel.self) var model
    @State private var showDuo = false
    @State private var showMerge = false
    var body: some View {
        if let p = model.selectedPerson, let d = model.personDetail {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 16) {
                        Avatar(name: p.name, size: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.name).font(.largeTitle.bold())
                            Text("In your archive from \(p.first.formatted(.dateTime.month(.wide).year())) to \(p.last.formatted(.dateTime.month(.wide).year()))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 14) {
                        stat(p.received.formatted(), "messages from them")
                        stat(p.inDMs.formatted(), "in your DM")
                        stat(p.inGroups.formatted(), "in groups")
                        if d.dmChat != nil { stat("\(d.dmSentPct)%", "of your DM is you") }
                    }
                    if d.numbers.count > 1 {
                        card("Numbers in this archive") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(d.numbers) { n in
                                    HStack(spacing: 8) {
                                        Text(n.display).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                        if n.isUnresolvedLID {
                                            Text("WhatsApp ID, not a phone number").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                }
                                Text("Shown as one person. Unmerge in Merge contacts to separate them.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button { showMerge = true } label: { Label("Merge with another number…", systemImage: "person.2.badge.gearshape") }
                        .sheet(isPresented: $showMerge) { MergeView(preselect: p).environment(model) }
                    if let dm = d.dmChat {
                        Button { model.section = .chats; model.openChat(dm) } label: {
                            Label("Open conversation (\(dm.count.formatted()) messages)", systemImage: "bubble.left.and.bubble.right")
                        }.buttonStyle(.borderedProminent)
                        Button { showDuo = true } label: { Label("Heartbeat", systemImage: "gift") }
                            .help("This conversation's own story: what you two said to each other")
                            .sheet(isPresented: $showDuo) { DuoWrappedView(chat: dm).environment(model) }
                    }
                    card("Messages from them, by year") {
                        Chart(d.yearly, id: \.year) { BarMark(x: .value("Year", $0.year), y: .value("Messages", $0.count)).foregroundStyle(Theme.accent) }
                            .frame(height: 180)
                    }
                    if !d.groups.isEmpty {
                        card("Where else you talk") {
                            VStack(spacing: 8) {
                                ForEach(d.groups, id: \.chatID) { g in
                                    Button { model.section = .chats; model.openChat(id: g.chatID) } label: {
                                        HStack { Avatar(name: g.name, group: true, size: 26); Text(g.name).lineLimit(1); Spacer()
                                            Text("\(g.count.formatted()) from them").foregroundStyle(.secondary) }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }.padding(24)
            }.background(Color(nsColor: .windowBackgroundColor))
        } else {
            EmptyStateView(
                symbol: "person.crop.circle",
                title: "Pick a person",
                message: "Choose someone on the left to see how your conversations with them changed over the years.",
                colors: AppTheme.Module.people.colors)
                .background(AppTheme.Surface.page)
        }
    }
    func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading) { Text(v).font(.title.bold()); Text(l).font(.caption).foregroundStyle(.secondary) }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
    func card<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { Text(title).font(.headline); c() }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
