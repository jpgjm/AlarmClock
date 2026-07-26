//
//  ClockDialPicker.swift
//  AlarmClock
//
//  Android の Material TimePicker (文字盤ダイヤル) 相当の時刻選択 UI。
//  iOS の標準 DatePicker には文字盤スタイルが存在しないため自作している。
//
//  構成:
//    - 上部ヘッダー: "HH : mm"。タップで時 / 分の編集フェーズを切り替える。
//    - 下部ダイヤル:
//        * 時フェーズ: 二重リング (外周 = 12,1..11 / 内周 = 00,13..23) の 24 時間表示
//        * 分フェーズ: 単一リング (00,05,...,55 のラベル、ドラッグは 1 分刻み)
//    - ドラッグまたはタップで選択。時を選び終えると自動的に分フェーズへ移る。
//
//  座標系:
//    角度 0° = 真上 (12 時位置)、時計回りが正。
//    画面座標は y が下向きなので、点 (dx, dy) の角度は atan2(dx, -dy) で求める。
//
//  リング判定 (時フェーズのみ):
//    中心からの距離が 外周半径と内周半径の中点 より小さければ内周 (13〜23, 00)。
//

import SwiftUI

struct ClockDialPicker: View {
    /// 0〜23 の時。
    @Binding var hour: Int
    /// 0〜59 の分。
    @Binding var minute: Int

    /// 編集中のフェーズ。
    private enum Phase {
        case hour
        case minute
    }
    @State private var phase: Phase = .hour

    var body: some View {
        VStack(spacing: 16) {
            header
            dial
                .frame(maxWidth: 300)
                .aspectRatio(1, contentMode: .fit)
            Text(phase == .hour ? "時をタップまたはドラッグで選択" : "分をタップまたはドラッグで選択")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 2) {
            Text(String(format: "%02d", hour))
                .font(.system(size: 48, weight: .light, design: .rounded))
                .foregroundStyle(phase == .hour ? Color.accentColor : Color.secondary)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { phase = .hour } }
                .accessibilityLabel("時 \(hour)")

            Text(":")
                .font(.system(size: 48, weight: .light, design: .rounded))
                .foregroundStyle(.secondary)

            Text(String(format: "%02d", minute))
                .font(.system(size: 48, weight: .light, design: .rounded))
                .foregroundStyle(phase == .minute ? Color.accentColor : Color.secondary)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { phase = .minute } }
                .accessibilityLabel("分 \(minute)")
        }
    }

    // MARK: - Dial

    private var dial: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let outerR = side / 2 - 22
            let innerR = outerR - 38

            ZStack {
                Circle()
                    .fill(Color(.tertiarySystemFill))

                hand(center: center, outerR: outerR, innerR: innerR)

                if phase == .hour {
                    // 外周: 12, 1, 2, ..., 11
                    ForEach(0..<12, id: \.self) { i in
                        numberLabel(
                            text: "\(i == 0 ? 12 : i)",
                            index: i,
                            radius: outerR,
                            center: center,
                            isSelected: !hourIsInner && outerIndex == i
                        )
                    }
                    // 内周: 00, 13, 14, ..., 23
                    ForEach(0..<12, id: \.self) { i in
                        numberLabel(
                            text: String(format: "%02d", i == 0 ? 0 : i + 12),
                            index: i,
                            radius: innerR,
                            center: center,
                            isSelected: hourIsInner && innerIndex == i,
                            isSmall: true
                        )
                    }
                } else {
                    // 分: 00, 05, ..., 55
                    ForEach(0..<12, id: \.self) { i in
                        numberLabel(
                            text: String(format: "%02d", i * 5),
                            index: i,
                            radius: outerR,
                            center: center,
                            isSelected: minute == i * 5
                        )
                    }
                }
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        update(at: value.location, center: center, outerR: outerR, innerR: innerR)
                    }
                    .onEnded { value in
                        update(at: value.location, center: center, outerR: outerR, innerR: innerR)
                        // 時を選び終えたら自動的に分フェーズへ (Android と同じ挙動)
                        if phase == .hour {
                            withAnimation(.easeInOut(duration: 0.2)) { phase = .minute }
                        }
                    }
            )
        }
    }

    /// 選択中の値を指す針 (中心 → ノブ)。
    @ViewBuilder
    private func hand(center: CGPoint, outerR: CGFloat, innerR: CGFloat) -> some View {
        let target = handTarget(outerR: outerR, innerR: innerR)
        let rad = target.angle * .pi / 180
        let knob = CGPoint(
            x: center.x + sin(rad) * target.radius,
            y: center.y - cos(rad) * target.radius
        )

        ZStack {
            Path { p in
                p.move(to: center)
                p.addLine(to: knob)
            }
            .stroke(Color.accentColor, lineWidth: 2)

            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .position(center)

            Circle()
                .fill(Color.accentColor.opacity(0.35))
                .frame(width: 38, height: 38)
                .position(knob)
        }
        .allowsHitTesting(false)
    }

    /// 文字盤上の数字ラベル 1 個。
    @ViewBuilder
    private func numberLabel(
        text: String,
        index: Int,
        radius: CGFloat,
        center: CGPoint,
        isSelected: Bool,
        isSmall: Bool = false
    ) -> some View {
        let rad = Double(index) * 30 * .pi / 180
        let pos = CGPoint(
            x: center.x + sin(rad) * radius,
            y: center.y - cos(rad) * radius
        )
        Text(text)
            .font(.system(size: isSmall ? 13 : 17, weight: isSelected ? .semibold : .regular, design: .rounded))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .position(pos)
            .allowsHitTesting(false)
    }

    // MARK: - Geometry helpers

    /// 内周 (00, 13〜23) を選択中かどうか。
    private var hourIsInner: Bool { hour == 0 || hour >= 13 }

    /// 内周でのインデックス (0 = 00, 1 = 13, ..., 11 = 23)。
    private var innerIndex: Int { hour == 0 ? 0 : hour - 12 }

    /// 外周でのインデックス (0 = 12, 1 = 1, ..., 11 = 11)。
    private var outerIndex: Int { hour == 12 ? 0 : hour }

    /// 針が指すべき角度 (度) と半径。
    private func handTarget(outerR: CGFloat, innerR: CGFloat) -> (angle: Double, radius: CGFloat) {
        switch phase {
        case .hour:
            return hourIsInner
                ? (Double(innerIndex) * 30, innerR)
                : (Double(outerIndex) * 30, outerR)
        case .minute:
            return (Double(minute) * 6, outerR)
        }
    }

    /// タッチ位置から時 / 分を更新する。
    private func update(at point: CGPoint, center: CGPoint, outerR: CGFloat, innerR: CGFloat) {
        let dx = point.x - center.x
        let dy = point.y - center.y

        // 真上を 0°、時計回りを正とする角度
        var degrees = atan2(dx, -dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }

        switch phase {
        case .hour:
            let index = Int((degrees / 30).rounded()) % 12
            let distance = hypot(dx, dy)
            let threshold = (outerR + innerR) / 2
            if distance < threshold {
                // 内周: 00, 13〜23
                hour = (index == 0) ? 0 : index + 12
            } else {
                // 外周: 12, 1〜11
                hour = (index == 0) ? 12 : index
            }
        case .minute:
            minute = Int((degrees / 6).rounded()) % 60
        }
    }
}
