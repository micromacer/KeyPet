import AppKit

/// One labeled continuous slider row for the menu. Size, opacity and reset
/// delay share this control; `format` renders the live value (nil = fixed
/// label only). Changes preview live; persistence happens on menu close.
@MainActor
final class MenuSliderView: NSView {
    var onChange: ((Double) -> Void)?
    private let slider: NSSlider
    private let valueField: NSTextField?
    private let format: ((Double) -> String)?

    init(title: String, value: Double, range: ClosedRange<Double>, format: ((Double) -> String)? = nil) {
        self.format = format
        slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        if format != nil {
            valueField = NSTextField(labelWithString: "")
        } else {
            valueField = nil
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 248, height: 64))
        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 13)
        // Leave room for longer translations without truncating the label or
        // colliding with the value. The native menu adopts the widest row.
        let labelWidth = max(140, ceil(label.fittingSize.width))
        let rowWidth = 18 + labelWidth + 8 + 74 + 16
        frame.size.width = rowWidth
        label.frame = NSRect(x: 18, y: 38, width: labelWidth, height: 18)
        addSubview(label)
        if let valueField {
            valueField.frame = NSRect(x: 18 + labelWidth + 8, y: 38, width: 74, height: 18)
            valueField.font = .menuFont(ofSize: 12)
            valueField.textColor = .secondaryLabelColor
            valueField.alignment = .right
            addSubview(valueField)
        }
        slider.frame = NSRect(x: 16, y: 10, width: rowWidth - 32, height: 24)
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.target = self
        slider.action = #selector(changed)
        slider.setAccessibilityLabel(title)
        addSubview(slider)
        update(value: value)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(value: Double) {
        slider.doubleValue = value
        valueField?.stringValue = format?(value) ?? ""
    }

    @objc private func changed() {
        valueField?.stringValue = format?(slider.doubleValue) ?? ""
        onChange?(slider.doubleValue)
    }
}
