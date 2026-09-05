// 通用二级页（设置类页面）的骨架。
//
// 设计稿把 device.detail / me.devices / me.caps / me.profile / me.workspace /
// set.conn / set.notify / set.general / set.about 九个页面做成了**同一套模板**：
//   头部卡（可选）→ 一段说明（可选）→ 若干「分组标题 + 卡片行 + 脚注」→ 结尾说明。
// 所以这里也做成一套组件而不是九个页面各画各的 —— 九份重复的行样式必然慢慢分叉。
//
// 行的三种右侧形态：值文字 / 开关 / 箭头。三者可以并存（值 + 箭头是最常见的组合）。
import SwiftUI

// MARK: - 行

struct UmbraSettingRow: Identifiable {
    let id = UUID()
    var label: String
    /// 主文下面的一行小字。
    var sub: String? = nil
    /// 右侧的值。路径、ID、Token 这类要等宽，见 `mono`。
    var value: String? = nil
    /// 值用等宽字体（路径、设备 ID、密钥、快捷键 —— 这是硬规则，不是风格偏好）。
    var mono: Bool = false
    /// 主文字色。默认正文色；橙色用于「保存并重连」这类动作行；--danger 用于破坏性行。
    var tint: Color? = nil
    var chevron: Bool = false
    /// 开关状态。非 nil 就画开关。
    var toggle: Bool? = nil
    var action: (() -> Void)? = nil
}

struct UmbraSettingSection: Identifiable {
    let id = UUID()
    var header: String? = nil
    var footer: String? = nil
    var rows: [UmbraSettingRow]
}

// MARK: - 开关
//
// 44×26 轨道 + 22 圆钮，开时 --orange、关时 --track，位移 .14s。
// 不用系统 Toggle：系统的尺寸和绿色都改不到设计值，而且它的点击区包含整行标签，
// 这里的行本身可能另有点击动作（值 + 箭头 + 开关并存的行）。
struct UmbraSwitch: View {
    var on: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? UmbraColor.orange : UmbraColor.track)
                Circle().fill(Color.white).frame(width: 22, height: 22).padding(2)
            }
            .frame(width: 44, height: 26)
            // 视觉 26 高，热区撑到 44（`minTapTarget`：视觉可以小于 44，热区不许）。
            // **只往上下撑**（`minTapTarget.negativeMarginAxis`，批次 015）：横向本来就是
            // 44，不需要动；真去动横向反而会咬到左边那段值文字 / 右边的箭头。
            // 上下各外溢 9pt，落在设置行自己的 11pt 纵向内边距里，串不到上下行。
            .padding(.vertical, (UmbraMetric.tapMin - 26) / 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 负边距把占位收回 26，行高不变 —— 否则每一行有开关的设置行都会高出 18pt。
        .padding(.vertical, -(UmbraMetric.tapMin - 26) / 2)
        .animation(UmbraMotion.tint, value: on)
    }
}

// MARK: - 头部卡
//
// 设备详情、我的首页顶部那张卡：48 图标块 + 名字 + 状态徽标 + 一行小字。
struct UmbraHeroCard: View {
    var iconPath: String
    var name: String
    var badge: String? = nil
    var badgeOn: Bool = true
    var sub: String? = nil
    var subMono: Bool = false

    var body: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                .fill(UmbraColor.chip)
                .frame(width: UmbraMetric.iconBlockXL, height: UmbraMetric.iconBlockXL)
                .overlay(
                    UmbraIcon(d: iconPath, size: 23, strokeWidth: 1.8)
                        .foregroundColor(UmbraColor.muted)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(name)
                    .font(UmbraFont.sans(17, .w560))
                    .foregroundColor(UmbraColor.text)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    if let b = badge {
                        // 徽标带一个点 + 文字。**不只靠颜色**：离线那档文字就是「离线」。
                        HStack(spacing: 5) {
                            Circle().fill(badgeOn ? UmbraColor.success : UmbraColor.faint)
                                .frame(width: 6, height: 6)
                            Text(b).font(UmbraFont.sans(11, .w600))
                        }
                        .foregroundColor(badgeOn ? UmbraColor.success : UmbraColor.faint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(badgeOn ? UmbraColor.successSoft : UmbraColor.chip))
                    }
                    if let s = sub {
                        Text(s)
                            .font(subMono ? UmbraFont.mono(12) : UmbraFont.sans(12, .w400))
                            .foregroundColor(UmbraColor.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
        )
    }
}

// MARK: - 分组卡片

struct UmbraSettingSectionView: View {
    let section: UmbraSettingSection

    var body: some View {
        VStack(alignment: .leading, spacing: UmbraMetric.sp2) {
            if let h = section.header, !h.isEmpty {
                UmbraFieldLabel(text: h)
                    .padding(.horizontal, UmbraMetric.pagePadX)
            }
            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { idx, row in
                    if idx > 0 { UmbraRowDivider() }
                    rowView(row)
                }
            }
            .background(RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous).fill(UmbraColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: UmbraMetric.radiusCard, style: .continuous)
                    .strokeBorder(UmbraColor.border, lineWidth: UmbraMetric.borderW)
            )
            .padding(.horizontal, UmbraMetric.pagePadX)

            if let f = section.footer, !f.isEmpty {
                Text(f)
                    .font(UmbraFont.sans(12, .w400))
                    .foregroundColor(UmbraColor.faint)
                    .lineSpacing(12 * 0.65)
                    .padding(.horizontal, UmbraMetric.pagePadX)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: UmbraSettingRow) -> some View {
        let inner = HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.label)
                    .font(row.mono && row.value == nil ? UmbraFont.mono(15) : UmbraFont.sans(16, .w400))
                    .foregroundColor(row.tint ?? UmbraColor.text)
                    .lineSpacing(16 * 0.4)
                    .multilineTextAlignment(.leading)
                if let s = row.sub {
                    Text(s)
                        .font(UmbraFont.sans(12.5, .w400))
                        .foregroundColor(UmbraColor.faint)
                        .lineSpacing(12.5 * 0.5)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let v = row.value {
                Text(v)
                    .font(row.mono ? UmbraFont.mono(13.5) : UmbraFont.sans(14.5, .w400))
                    .foregroundColor(UmbraColor.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
            if let on = row.toggle {
                UmbraSwitch(on: on) { row.action?() }
            }
            if row.chevron {
                UmbraIcon(d: UmbraIconPath.chevronRight, size: 15, strokeWidth: 2.2)
                    .foregroundColor(UmbraColor.faint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 48)

        // 有开关的行，点击区归开关（否则点标签也会切，容易误触）；
        // 其它有动作的行整行可点。
        if row.toggle == nil, let act = row.action {
            Button(action: act) { inner.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            inner
        }
    }
}

// MARK: - 整页
//
// 顶栏 + 头部卡 + 说明 + 若干分组 + 额外内容（编辑框之类）+ 破坏性按钮 + 结尾说明。
struct UmbraSettingsPage<Extra: View>: View {
    var backLabel: String
    var title: String
    var onBack: () -> Void
    var hero: (() -> AnyView)? = nil
    var intro: String? = nil
    var sections: [UmbraSettingSection] = []
    var footnote: String? = nil
    /// 破坏性动作（「从联系人列表移除」这类）。**只放在这里**，不进分组行。
    var danger: (label: String, action: () -> Void)? = nil
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        // v2：导航交给系统（返回钮/边缘手势/标题都是系统的）。
        // backLabel / onBack 参数保留只为不动十几个调用点 —— 系统返回自己会弹栈。
        UmbraScreen(content: {
            VStack(alignment: .leading, spacing: UmbraMetric.sp6) {
                if let hero {
                    hero().padding(.horizontal, UmbraMetric.pagePadX)
                }
                if let intro, !intro.isEmpty {
                    Text(intro)
                        .font(UmbraFont.sans(12.5, .w400))
                        .foregroundColor(UmbraColor.muted)
                        .lineSpacing(12.5 * 0.7)
                        .padding(.horizontal, UmbraMetric.pagePadX)
                }
                ForEach(sections) { UmbraSettingSectionView(section: $0) }

                extra()

                if let d = danger {
                    UmbraButton(title: d.label, kind: .dangerOutline, action: d.action)
                        .padding(.horizontal, UmbraMetric.pagePadX)
                }
                if let f = footnote, !f.isEmpty {
                    Text(f)
                        .font(UmbraFont.sans(12, .w400))
                        .foregroundColor(UmbraColor.faint)
                        .lineSpacing(12 * 0.7)
                        .padding(.horizontal, UmbraMetric.pagePadX)
                }
            }
            .padding(.top, UmbraMetric.sp5)
        })
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension UmbraSettingsPage where Extra == EmptyView {
    init(backLabel: String, title: String, onBack: @escaping () -> Void,
         hero: (() -> AnyView)? = nil, intro: String? = nil,
         sections: [UmbraSettingSection] = [], footnote: String? = nil,
         danger: (label: String, action: () -> Void)? = nil) {
        self.init(backLabel: backLabel, title: title, onBack: onBack, hero: hero,
                  intro: intro, sections: sections, footnote: footnote,
                  danger: danger, extra: { EmptyView() })
    }
}
