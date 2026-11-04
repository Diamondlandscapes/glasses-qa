import Foundation
@preconcurrency import MWDATCore

enum GlassesDeviceReport {
    static func typeName(_ type: DeviceType) -> String {
        switch type {
        case .metaRayBanDisplay:
            return "Ray-Ban Display"
        case .rayBanMeta:
            return "Ray-Ban Meta"
        case .rayBanMetaOptics:
            return "Ray-Ban Meta Optics"
        case .oakleyMetaHSTN:
            return "Oakley Meta HSTN"
        case .oakleyMetaVanguard:
            return "Oakley Meta Vanguard"
        case .metaGlasses:
            return "Meta glasses"
        case .unknown:
            return "Unknown glasses"
        @unknown default:
            return type.rawValue
        }
    }

    static func line(_ device: Device) -> String {
        var parts = [
            device.nameOrId(),
            typeName(device.deviceType()),
            linkName(device.linkState),
            compatibilityName(device.compatibility())
        ]
        if device.donState == .doffed {
            parts.append("not being worn")
        } else if device.donState == .donned {
            parts.append("worn")
        }
        if device.hingeState == .closed {
            parts.append("folded")
        } else if device.hingeState == .open {
            parts.append("unfolded")
        }
        return parts.joined(separator: " · ")
    }

    static func summary(_ wearables: any WearablesInterface) -> String {
        let lines = wearables.devices.compactMap { wearables.deviceForIdentifier($0).map(line) }
        return lines.isEmpty ? "No glasses reported." : lines.joined(separator: "\n")
    }

    static func permissionMessage(_ error: Error) -> String {
        guard let error = error as? PermissionError else {
            return error.localizedDescription
        }
        switch error {
        case .noDevice:
            return "No glasses found yet. Pair them in Meta AI, then try again."
        case .noDeviceWithConnection:
            return "The glasses aren't connected. Unfold them and put them on."
        case .connectionError:
            return "The phone lost the connection to the glasses."
        case .metaAINotInstalled:
            return "Install the Meta AI app, then try again."
        case .requestInProgress:
            return "A camera permission request is already open in Meta AI."
        case .requestTimeout:
            return "Meta AI didn't answer the camera permission request."
        case .internalError:
            return "Camera permission failed inside the glasses SDK."
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func linkName(_ state: LinkState) -> String {
        switch state {
        case .connected:
            return "connected"
        case .connecting:
            return "connecting"
        case .disconnected:
            return "disconnected"
        }
    }

    private static func compatibilityName(_ compatibility: Compatibility) -> String {
        switch compatibility {
        case .compatible:
            return "compatible"
        case .undefined:
            return "compatibility not ready"
        case .deviceUpdateRequired:
            return "firmware update required"
        case .sdkUpdateRequired:
            return "SDK update required"
        @unknown default:
            return compatibility.displayString
        }
    }
}
