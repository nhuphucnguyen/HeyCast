import Carbon.HIToolbox

/// Input source switching via Carbon TIS, so the launcher can pin a keyboard
/// layout while it's open and restore the previous one on close.
enum InputSourceService {
    static func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return propertyValue(source, kTISPropertyInputSourceID)
    }

    static func select(sourceID: String) -> Bool {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        for source in list {
            if propertyValue(source, kTISPropertyInputSourceID) == sourceID {
                return TISSelectInputSource(source) == noErr
            }
        }
        return false
    }

    private static func propertyValue(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
