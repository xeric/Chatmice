//
//  PersonaSelectorView.swift
//  Chatmice
//
//  Created by Renat Notfullin on 08.11.2024.
//

import AppKit
import CoreData
import SwiftUI

enum PersonaAppearance {
    static let defaultColor = "#FF4444"
    static let defaultSymbol = "person.fill"

    static func color(for persona: PersonaEntity?) -> Color {
        Color(hex: persona?.color ?? defaultColor) ?? Color(hex: defaultColor) ?? .red
    }

    static func symbolName(for persona: PersonaEntity?) -> String {
        validatedSymbol(persona?.symbolName, fallback: defaultSymbol)
    }

    static func overlaySymbolName(for persona: PersonaEntity?) -> String? {
        guard let name = persona?.symbolOverlayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              isValidSymbol(name) else { return nil }
        return name
    }

    static func validatedSymbol(_ name: String?, fallback: String) -> String {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              isValidSymbol(name) else { return fallback }
        return name
    }

    static func isValidSymbol(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    static func defaultSymbol(for personaName: String?) -> String {
        switch personaName {
        case "Default Assistant": return "person.fill"
        case "Software Engineer": return "laptopcomputer"
        case "AI Expert": return "sparkles"
        case "Natural Sciences Expert": return "globe.americas.fill"
        case "History Buff": return "books.vertical.fill"
        case "Fitness Trainer": return "dumbbell.fill"
        case "Dietologist": return "leaf.fill"
        case "DBT Psychologist": return "brain.head.profile"
        default: return defaultSymbol
        }
    }
}

struct PersonaIconView: View {
    let color: Color
    let symbolName: String
    let overlaySymbolName: String?
    let size: CGFloat

    init(persona: PersonaEntity?, size: CGFloat) {
        color = PersonaAppearance.color(for: persona)
        symbolName = PersonaAppearance.symbolName(for: persona)
        overlaySymbolName = PersonaAppearance.overlaySymbolName(for: persona)
        self.size = size
    }

    init(color: Color, symbolName: String, overlaySymbolName: String?, size: CGFloat) {
        self.color = color
        self.symbolName = PersonaAppearance.validatedSymbol(
            symbolName,
            fallback: PersonaAppearance.defaultSymbol
        )
        self.overlaySymbolName = overlaySymbolName.flatMap {
            PersonaAppearance.isValidSymbol($0) ? $0 : nil
        }
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color)

            Image(systemName: symbolName)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
                .symbolRenderingMode(.monochrome)

            if let overlaySymbolName {
                ZStack {
                    Circle().fill(.white)
                    Image(systemName: overlaySymbolName)
                        .font(.system(size: size * 0.19, weight: .bold))
                        .foregroundStyle(color)
                }
                .frame(width: size * 0.43, height: size * 0.43)
                .offset(x: size * 0.31, y: size * 0.31)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
enum PersonaSelection {
    static func apply(_ persona: PersonaEntity, to chat: ChatEntity) {
        chat.persona = persona
        chat.systemMessage = persona.systemMessage ?? AppConstants.chatGptSystemMessage
        chat.objectWillChange.send()
        try? chat.managedObjectContext?.save()
    }
}

struct PersonaPickerPopoverView: View {
    let personas: [PersonaEntity]
    let selectedPersona: PersonaEntity?
    let onSelect: (PersonaEntity) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            currentPersonaSection

            Divider()

            Text("Switch Assistant")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(personas, id: \.objectID) { persona in
                        personaButton(persona)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 340, height: 420)
    }

    private var currentPersonaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PersonaIconView(persona: selectedPersona, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedPersona?.name ?? "No Assistant")
                        .font(.headline)
                    Text("Current prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                Text(selectedPersona?.systemMessage ?? AppConstants.chatGptSystemMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
    }

    private func personaButton(_ persona: PersonaEntity) -> some View {
        Button {
            onSelect(persona)
        } label: {
            HStack(spacing: 10) {
                PersonaIconView(persona: persona, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(persona.name ?? "Unnamed Assistant")
                        .font(.system(size: 12, weight: .medium))
                    Text(persona.systemMessage ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if persona.objectID == selectedPersona?.objectID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background {
                if persona.objectID == selectedPersona?.objectID {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.12))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct PersonaSymbolOption: Identifiable {
    let name: String
    let keywords: String

    var id: String { name }

    func matches(_ query: String) -> Bool {
        name.localizedCaseInsensitiveContains(query)
            || keywords.localizedCaseInsensitiveContains(query)
    }
}

enum PersonaSymbolCatalog {
    static let baseOptions = valid([
        option("person.fill", "person people user profile default human 用户 人物"),
        option("person.crop.circle.fill", "avatar account profile user portrait 头像 账户"),
        option("person.2.fill", "people team couple group users 团队 双人"),
        option("person.3.fill", "people team community group family 群组 社区"),
        option("figure.stand", "person body standing human 人 站立"),
        option("figure.walk", "walk walking activity movement 步行"),
        option("figure.run", "run running cardio fitness 跑步 健身"),
        option("figure.strengthtraining.traditional", "strength weights gym fitness workout 力量 健身"),
        option("figure.mind.and.body", "mindfulness meditation psychology wellness yoga 心理 冥想"),
        option("accessibility", "accessibility person inclusive support 辅助 无障碍"),
        option("sparkles", "ai magic assistant stars intelligence 人工智能 魔法"),
        option("brain.head.profile", "brain mind psychology ai intelligence mental 心理 大脑"),
        option("cpu.fill", "processor chip computer ai hardware 处理器 芯片"),
        option("memorychip.fill", "memory chip computer hardware ram 内存 芯片"),
        option("network", "network graph connected internet nodes 网络 连接"),
        option("point.3.connected.trianglepath.dotted", "neural network graph ai nodes 神经网络"),
        option("function", "math code formula programming equation 函数 数学"),
        option("command", "command shortcut terminal code 命令 快捷键"),
        option("terminal.fill", "terminal shell command developer code 终端 开发"),
        option("chevron.left.forwardslash.chevron.right", "code programming developer software 编程 代码"),
        option("laptopcomputer", "laptop computer software developer work 笔记本 电脑"),
        option("desktopcomputer", "desktop computer workstation monitor 电脑 工作站"),
        option("server.rack", "server backend database infrastructure 服务器 后端"),
        option("externaldrive.fill", "storage drive disk database backup 存储 硬盘"),
        option("cloud.fill", "cloud online sync internet 云 同步"),
        option("wifi", "wireless network internet connection 无线 网络"),
        option("atom", "science physics chemistry atom research 科学 物理"),
        option("flask.fill", "science chemistry laboratory experiment 化学 实验"),
        option("testtube.2", "science chemistry laboratory test experiment 试管 实验"),
        option("globe.americas.fill", "earth world geography natural science planet 地球 科学"),
        option("globe.europe.africa.fill", "earth world geography travel 地球 地理"),
        option("globe.asia.australia.fill", "earth world geography asia 地球 亚洲"),
        option("leaf.fill", "nature ecology biology environment diet green 叶子 自然"),
        option("tree.fill", "nature forest environment ecology tree 自然 森林"),
        option("mountain.2.fill", "nature outdoors geology mountain hiking 山 地质"),
        option("drop.fill", "water liquid environment weather 水 液体"),
        option("flame.fill", "fire energy hot motivation 火 能量"),
        option("bolt.fill", "electricity energy power lightning 电力 能量"),
        option("snowflake", "cold winter weather climate 雪 冬季"),
        option("sun.max.fill", "sun weather astronomy daylight 太阳 天气"),
        option("moon.stars.fill", "moon astronomy night space 月亮 天文"),
        option("pawprint.fill", "animal pet biology wildlife 动物 宠物"),
        option("books.vertical.fill", "books history library reading education 书籍 历史"),
        option("book.closed.fill", "book reading knowledge education 书 阅读"),
        option("text.book.closed.fill", "textbook study manual knowledge 教材 学习"),
        option("scroll.fill", "history document ancient archive 历史 卷轴"),
        option("building.columns.fill", "history museum government law classical 历史 博物馆"),
        option("graduationcap.fill", "education teacher student academic school 教育 学校"),
        option("globe.desk.fill", "geography education history world 地理 教育"),
        option("hourglass", "history time deadline duration 时间 历史"),
        option("clock.arrow.circlepath", "history time restore past 时间 过去"),
        option("map.fill", "map geography travel location 地图 地理"),
        option("dumbbell.fill", "fitness gym strength trainer weights 健身 哑铃"),
        option("sportscourt.fill", "sports fitness court training 体育 运动"),
        option("medal.fill", "sports achievement coach award 奖牌 成就"),
        option("trophy.fill", "winner sports achievement award 奖杯 成就"),
        option("heart.fill", "health love care wellness fitness 心脏 健康"),
        option("heart.text.square.fill", "health medical psychology care 心理 健康"),
        option("waveform.path.ecg", "health medical heartbeat cardiology 医疗 心电"),
        option("cross.case.fill", "medical doctor health first aid 医疗 急救"),
        option("stethoscope", "doctor medical healthcare physician 医生 医疗"),
        option("pills.fill", "medicine pharmacy health medication 药物 医疗"),
        option("syringe.fill", "medical vaccine health injection 医疗 注射"),
        option("bandage.fill", "medical first aid recovery health 医疗 绷带"),
        option("person.bubble.fill", "psychology therapy counseling communication 心理 咨询"),
        option("bubble.left.and.bubble.right.fill", "conversation therapy communication coaching 对话 咨询"),
        option("fork.knife", "food diet nutrition restaurant 饮食 营养"),
        option("carrot.fill", "food diet vegetables nutrition healthy 胡萝卜 饮食"),
        option("cup.and.saucer.fill", "drink cafe coffee food 咖啡 饮品"),
        option("takeoutbag.and.cup.and.straw.fill", "food meal restaurant takeout 食物 外卖"),
        option("birthday.cake.fill", "cake food celebration dessert 蛋糕 甜点"),
        option("briefcase.fill", "business work professional career 商务 工作"),
        option("chart.line.uptrend.xyaxis", "finance analytics growth business chart 金融 分析"),
        option("banknote.fill", "money finance business cash 金融 金钱"),
        option("creditcard.fill", "payment finance money card 支付 金融"),
        option("hammer.fill", "build repair craft law tool 工具 建造"),
        option("wrench.and.screwdriver.fill", "tools repair engineering maintenance 工具 工程"),
        option("paintbrush.fill", "art design creative painting 设计 艺术"),
        option("pencil.and.outline", "writing edit author creative 写作 编辑"),
        option("lightbulb.fill", "idea creativity insight innovation 想法 创意"),
        option("wand.and.stars", "magic creative ai assistant 魔法 创意"),
        option("camera.fill", "photo photography visual media 相机 摄影"),
        option("music.note", "music audio composer sound 音乐 音频"),
        option("microphone.fill", "voice audio podcast speaking 麦克风 语音"),
        option("film.fill", "movie video cinema media 电影 视频"),
        option("theatermasks.fill", "theater drama performance art 戏剧 表演"),
        option("gamecontroller.fill", "game gaming entertainment 游戏 娱乐"),
        option("megaphone.fill", "marketing announcement communication 营销 公告"),
        option("message.fill", "message chat communication support 消息 对话"),
        option("envelope.fill", "email mail communication 邮件 通信"),
        option("phone.fill", "phone call support communication 电话 通信"),
        option("video.fill", "video call camera meeting 视频 会议"),
        option("airplane", "travel aviation flight trip 飞机 旅行"),
        option("car.fill", "car transport travel vehicle 汽车 交通"),
        option("bicycle", "bike cycling fitness transport 自行车 骑行"),
        option("train.side.front.car", "train transport travel railway 火车 交通"),
        option("sailboat.fill", "boat travel ocean sailing 船 航海"),
        option("house.fill", "home family real estate 房屋 家庭"),
        option("building.2.fill", "city business office architecture 城市 建筑"),
        option("tent.fill", "camping outdoors travel nature 露营 户外"),
        option("suitcase.fill", "travel luggage trip business 旅行 行李"),
        option("location.fill", "location navigation place map 位置 导航"),
        option("safari.fill", "compass navigation explore browser 指南针 探索"),
        option("lock.fill", "security privacy protection lock 安全 隐私"),
        option("key.fill", "security access password authentication 安全 密钥"),
        option("shield.fill", "security protection safety privacy 安全 防护"),
        option("checkmark.shield.fill", "security verified trusted protection 安全 验证"),
        option("eye.fill", "vision review observe accessibility 观察 视觉"),
        option("fingerprint", "security identity biometric privacy 指纹 身份"),
        option("faceid", "security identity face biometric 面容 身份"),
        option("magnifyingglass", "search research inspect analyze 搜索 研究"),
        option("doc.text.fill", "document writing report text 文档 报告"),
        option("folder.fill", "files organization archive folder 文件 文件夹"),
        option("calendar", "calendar schedule planning date 日历 计划"),
        option("checklist", "tasks plan checklist productivity 清单 任务"),
        option("gearshape.fill", "settings engineering configuration gear 设置 配置"),
        option("questionmark.circle.fill", "help question support faq 帮助 问题"),
        option("exclamationmark.triangle.fill", "warning risk alert caution 警告 风险")
    ])

    static let overlayOptions = valid([
        option("checkmark", "done success selected complete 完成 对勾"),
        option("xmark", "close remove cancel error 关闭 取消"),
        option("plus", "add new create positive 添加 新建"),
        option("minus", "remove subtract reduce 删除 减少"),
        option("star.fill", "favorite featured special star 收藏 星标"),
        option("heart.fill", "love health care favorite 爱心 健康"),
        option("bolt.fill", "fast power energy lightning 快速 能量"),
        option("sparkles", "ai magic new special 人工智能 魔法"),
        option("crown.fill", "premium leader expert crown 专家 皇冠"),
        option("flame.fill", "hot trending fire energy 热门 火焰"),
        option("shield.fill", "security protection safe 安全 防护"),
        option("lock.fill", "private secure locked 隐私 锁定"),
        option("key.fill", "access security key 权限 密钥"),
        option("wrench.fill", "tool repair settings 工具 维修"),
        option("hammer.fill", "build tool work 建造 工具"),
        option("magnifyingglass", "search inspect research 搜索 检查"),
        option("exclamationmark", "warning important alert 警告 重要"),
        option("questionmark", "help unknown question 帮助 问题"),
        option("info", "information details help 信息 详情"),
        option("bell.fill", "notification alert reminder 通知 提醒"),
        option("bookmark.fill", "bookmark save remember 书签 保存"),
        option("flag.fill", "flag report goal marker 旗帜 标记"),
        option("pin.fill", "pin attach location 固定 图钉"),
        option("location.fill", "place location map 位置 地图"),
        option("paperclip", "attachment file clip 附件 文件"),
        option("link", "link url connected 链接 连接"),
        option("pencil", "edit write modify 编辑 修改"),
        option("trash.fill", "delete remove bin 删除 垃圾桶"),
        option("person.fill", "person user owner 人物 用户"),
        option("person.2.fill", "team users group 团队 群组"),
        option("message.fill", "message chat comment 消息 评论"),
        option("envelope.fill", "email mail 邮件 通信"),
        option("phone.fill", "phone call 电话 通话"),
        option("camera.fill", "camera photo image 相机 照片"),
        option("microphone.fill", "voice audio record 语音 录音"),
        option("play.fill", "play start run 播放 开始"),
        option("pause.fill", "pause hold stop 暂停 停止"),
        option("arrow.up", "up upload improve increase 向上 上传"),
        option("arrow.down", "down download decrease 向下 下载"),
        option("arrow.right", "next forward continue 下一步 继续"),
        option("arrow.clockwise", "refresh retry repeat 刷新 重试"),
        option("clock.fill", "time recent schedule 时间 最近"),
        option("calendar", "date schedule event 日期 日程"),
        option("globe", "world web global 世界 网络"),
        option("leaf.fill", "nature green healthy 自然 健康"),
        option("brain.head.profile", "brain ai psychology mind 大脑 心理")
    ])

    private static func option(_ name: String, _ keywords: String) -> PersonaSymbolOption {
        PersonaSymbolOption(name: name, keywords: keywords)
    }

    private static func valid(_ options: [PersonaSymbolOption]) -> [PersonaSymbolOption] {
        options.filter { PersonaAppearance.isValidSymbol($0.name) }
    }
}

struct PersonaSymbolPicker: View {
    @Binding var symbolName: String
    @Binding var overlaySymbolName: String
    @State private var searchText = ""
    @State private var overlaySearchText = ""

    private var filteredSymbols: [PersonaSymbolOption] {
        guard !searchText.isEmpty else { return PersonaSymbolCatalog.baseOptions }
        return PersonaSymbolCatalog.baseOptions.filter { $0.matches(searchText) }
    }

    private var filteredOverlaySymbols: [PersonaSymbolOption] {
        guard !overlaySearchText.isEmpty else { return PersonaSymbolCatalog.overlayOptions }
        return PersonaSymbolCatalog.overlayOptions.filter { $0.matches(overlaySearchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search symbols by name or keyword", text: $searchText)
                .textFieldStyle(.roundedBorder)

            symbolGrid(filteredSymbols, selected: symbolName) { symbolName = $0 }
                .frame(height: 132)

            HStack {
                TextField("Custom SF Symbol name", text: $symbolName)
                    .textFieldStyle(.roundedBorder)
                validationIndicator(for: symbolName, allowsEmpty: false)
            }

            Divider()

            HStack {
                Text("Optional composed badge")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("None") { overlaySymbolName = "" }
                    .buttonStyle(.bordered)
            }

            TextField("Search badge symbols by name or keyword", text: $overlaySearchText)
                .textFieldStyle(.roundedBorder)

            symbolGrid(filteredOverlaySymbols, selected: overlaySymbolName) { overlaySymbolName = $0 }
                .frame(height: 96)

            HStack {
                TextField("Custom badge SF Symbol name", text: $overlaySymbolName)
                    .textFieldStyle(.roundedBorder)
                validationIndicator(for: overlaySymbolName, allowsEmpty: true)
            }
        }
    }

    private func symbolGrid(
        _ options: [PersonaSymbolOption],
        selected: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        ScrollView {
            if options.isEmpty {
                Text("No matching symbols. You can still enter any valid SF Symbol name below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
                    ForEach(options) { option in
                        symbolButton(option.name, selected: selected == option.name) {
                            onSelect(option.name)
                        }
                    }
                }
            }
        }
    }

    private func symbolButton(
        _ symbol: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.accentColor : Color.primary.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol)
        .help(symbol)
    }

    @ViewBuilder
    private func validationIndicator(for symbol: String, allowsEmpty: Bool) -> some View {
        let valid = (allowsEmpty && symbol.isEmpty) || PersonaAppearance.isValidSymbol(symbol)
        Image(systemName: valid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(valid ? Color.green : Color.orange)
            .help(valid ? "Valid SF Symbol" : "Unknown SF Symbol; the default icon will be used")
    }
}
