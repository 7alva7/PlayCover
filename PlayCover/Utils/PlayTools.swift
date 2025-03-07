//
//  PlayTools.swift
//  PlayCover
//

import Foundation
import injection

// swiftlint:disable type_body_length
// swiftlint:disable file_length
// swiftlint:disable function_body_length

class PlayTools {
    private static let frameworksURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Frameworks")
    private static let playToolsFramework = frameworksURL
        .appendingPathComponent("PlayTools")
        .appendingPathExtension("framework")
    private static let playToolsPath = playToolsFramework
        .appendingPathComponent("PlayTools")
    private static let akInterfacePath = playToolsFramework
        .appendingPathComponent("PlugIns")
        .appendingPathComponent("AKInterface")
        .appendingPathExtension("bundle")
    private static let bundledPlayToolsFramework = Bundle.main.bundleURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("Frameworks")
        .appendingPathComponent("PlayTools")
        .appendingPathExtension("framework")

    public static var playCoverContainer: URL {
        let playCoverPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("io.playcover.PlayCover")
        if !FileManager.default.fileExists(atPath: playCoverPath.path) {
            do {
                try FileManager.default.createDirectory(at: playCoverPath,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                Log.shared.error(error)
            }
        }

        return playCoverPath
    }

    static func installOnSystem() {
        Task(priority: .background) {
            do {
                Log.shared.log("Installing PlayTools")

                // Check if Frameworks folder exists, if not, create it
                if !FileManager.default.fileExists(atPath: frameworksURL.path) {
                    try FileManager.default.createDirectory(
                        atPath: frameworksURL.path,
                        withIntermediateDirectories: true,
                        attributes: [:])
                }

                // Check if a version of PlayTools is already installed, if so remove it
                FileManager.default.delete(at: URL(fileURLWithPath: playToolsFramework.path))

                // Install version of PlayTools bundled with PlayCover
                Log.shared.log("Copying PlayTools to Frameworks")
                if FileManager.default.fileExists(atPath: playToolsFramework.path) {
                    try FileManager.default.removeItem(at: playToolsFramework)
                }
                try FileManager.default.copyItem(at: bundledPlayToolsFramework, to: playToolsFramework)
            } catch {
                Log.shared.error(error)
            }
        }
    }

    static func stripBinary(_ exec: URL) throws {
        let binary = try Data(contentsOf: exec)
        var header = binary.extract(fat_header.self)
        var offset = MemoryLayout.size(ofValue: header)
        let shouldSwap = header.magic == FAT_CIGAM

        if header.magic == FAT_MAGIC || header.magic == FAT_CIGAM {
            // Make sure the endianness is correct
            if shouldSwap {
                swap_fat_header(&header, NXHostByteOrder())
            }

            for _ in 0..<header.nfat_arch {
                var arch = binary.extract(fat_arch.self, offset: offset)
                if shouldSwap {
                    swap_fat_arch(&arch, 1, NXHostByteOrder())
                }

                if arch.cputype == CPU_TYPE_ARM64 {
                    print("Found ARM64 arch in fat binary")

                    let thinBinary = binary
                        .subdata(in: Int(arch.offset)..<Int(arch.offset+arch.size))
                    try FileManager.default.removeItem(at: exec)
                    try thinBinary.write(to: exec)

                    return
                }

                offset += Int(MemoryLayout.size(ofValue: arch))
            }

            throw PlayCoverError.failedToStripBinary
        } else {
            print("Binary already thin")
        }
    }

    static func installInIPA(_ exec: URL) throws {
        try stripBinary(exec)
        Inject.injectMachO(machoPath: exec.path,
                           cmdType: LC_Type.LOAD_DYLIB,
                           backup: false,
                           injectPath: playToolsPath.path,
                           finishHandle: { result in
            if result {
                do {
                    try installPluginInIPA(exec.deletingLastPathComponent())
                    shell.signApp(exec)
                } catch {
                    Log.shared.error(error)
                }
            }
        })
    }

    static func installPluginInIPA(_ payload: URL) throws {
        let pluginsURL = payload.appendingPathComponent("PlugIns")
        if !FileManager.default.fileExists(atPath: pluginsURL.path) {
            try FileManager.default.createDirectory(at: pluginsURL, withIntermediateDirectories: true)
        }

        let bundleTarget = pluginsURL
            .appendingPathComponent("AKInterface")
            .appendingPathExtension("bundle")

        let akInterface = bundledPlayToolsFramework.appendingPathComponent("PlugIns")
            .appendingPathComponent("AKInterface")
            .appendingPathExtension("bundle")

        if FileManager.default.fileExists(atPath: bundleTarget.path) {
            try FileManager.default.removeItem(at: bundleTarget)
        }
        try FileManager.default.copyItem(at: akInterface, to: bundleTarget)
        try bundleTarget.fixExecutable()
        Shell.codesign(bundleTarget)
    }

    static func injectInIPA(_ exec: URL, payload: URL) throws {
        try stripBinary(exec)
        Inject.injectMachO(machoPath: exec.path,
                           cmdType: LC_Type.LOAD_DYLIB,
                           backup: false,
                           injectPath: "@executable_path/Frameworks/PlayTools.dylib",
                           finishHandle: { result in
            if result {
                Task(priority: .background) {
                    do {
                        if !FileManager.default.fileExists(atPath: payload.appendingPathComponent("Frameworks").path) {
                            try FileManager.default.createDirectory(
                                at: payload.appendingPathComponent("Frameworks"),
                                withIntermediateDirectories: true)
                        }
                        if !FileManager.default.fileExists(atPath: payload.appendingPathComponent("PlugIns").path) {
                            try FileManager.default.createDirectory(
                                at: payload.appendingPathComponent("PlugIns"),
                                withIntermediateDirectories: true)
                        }

                        let libraryTarget = payload.appendingPathComponent("Frameworks")
                            .appendingPathComponent("PlayTools")
                            .appendingPathExtension("dylib")
                        let bundleTarget = payload.appendingPathComponent("PlugIns")
                            .appendingPathComponent("AKInterface")
                            .appendingPathExtension("bundle")

                        let tools = bundledPlayToolsFramework
                            .appendingPathComponent("PlayTools")
                        let akInterface = bundledPlayToolsFramework.appendingPathComponent("PlugIns")
                            .appendingPathComponent("AKInterface")
                            .appendingPathExtension("bundle")

                        if FileManager.default.fileExists(atPath: libraryTarget.path) {
                            try FileManager.default.removeItem(at: libraryTarget)
                        }
                        try FileManager.default.copyItem(at: tools, to: libraryTarget)

                        if FileManager.default.fileExists(atPath: bundleTarget.path) {
                            try FileManager.default.removeItem(at: bundleTarget)
                        }
                        try FileManager.default.copyItem(at: akInterface, to: bundleTarget)

                        try libraryTarget.fixExecutable()
                        try bundleTarget.fixExecutable()
                        Shell.codesign(bundleTarget)
                    } catch {
                        Log.shared.error(error)
                    }
                }
            }
        })
    }

    static func removeFromApp(_ exec: URL) {
        Inject.removeMachO(machoPath: exec.path,
                           cmdType: LC_Type.LOAD_DYLIB,
                           backup: false,
                           injectPath: playToolsPath.path,
                           finishHandle: { result in
            if result {
                do {
                    let pluginUrl = exec.deletingLastPathComponent()
                        .appendingPathComponent("PlugIns")
                        .appendingPathComponent("AKInterface")
                        .appendingPathExtension("bundle")

                    if FileManager.default.fileExists(atPath: pluginUrl.path) {
                        try FileManager.default.removeItem(at: pluginUrl)
                    }

                    shell.signApp(exec)
                } catch {
                    Log.shared.error(error)
                }
            }
        })
    }

    static func convertMacho(_ macho: URL) throws {
        print("Converting MachO at \(macho.path)")
        print("Stripping MachO")
        try stripBinary(macho)
        print("Removing old version command from MachO")
        try removeOldCommand(macho)
        print("Injecting new version command in MachO")
        try injectNewCommand(macho)
    }

    static func removeOldCommand(_ url: URL) throws {
        var binary = try Data(contentsOf: url)
        var newheader: mach_header_64
        var newHeaderData: Data?
        var machoRange: Range<Data.Index>?
        var start: Int?
        var size: Int?
        var end: Int?

        let header = binary.extract(mach_header_64.self)
        var offset = MemoryLayout.size(ofValue: header)

        for _ in 0..<header.ncmds {
            let loadCommand = binary.extract(load_command.self, offset: offset)
            switch UInt32(loadCommand.cmd) {
            case UInt32(LC_VERSION_MIN_IPHONEOS), UInt32(LC_VERSION_MIN_MACOSX):
                let versionCommand = binary.extract(version_min_command.self, offset: offset)

                start = offset
                size = Int(versionCommand.cmdsize)
                newheader = mach_header_64(magic: header.magic,
                                           cputype: header.cputype,
                                           cpusubtype: header.cpusubtype,
                                           filetype: header.filetype,
                                           ncmds: header.ncmds - 1,
                                           sizeofcmds: header.sizeofcmds - UInt32(versionCommand.cmdsize),
                                           flags: header.flags,
                                           reserved: header.reserved)
                newHeaderData = Data(bytes: &newheader, count: MemoryLayout<mach_header_64>.size)
                machoRange = Range(NSRange(location: 0, length: MemoryLayout<mach_header_64>.size))!
            case UInt32(LC_BUILD_VERSION):
                let versionCommand = binary.extract(build_version_command.self, offset: offset)

                start = offset
                size = Int(versionCommand.cmdsize)
                newheader = mach_header_64(magic: header.magic,
                                           cputype: header.cputype,
                                           cpusubtype: header.cpusubtype,
                                           filetype: header.filetype,
                                           ncmds: header.ncmds - 1,
                                           sizeofcmds: header.sizeofcmds - UInt32(versionCommand.cmdsize),
                                           flags: header.flags,
                                           reserved: header.reserved)
                newHeaderData = Data(bytes: &newheader, count: MemoryLayout<mach_header_64>.size)
                machoRange = Range(NSRange(location: 0, length: MemoryLayout<mach_header_64>.size))!
            default:
                break
            }
            offset += Int(loadCommand.cmdsize)
        }
        end = offset

        if let start = start,
           let end = end,
           let size = size,
           let machoRange = machoRange,
           let newHeaderData = newHeaderData {
            let subrangeNew = Range(NSRange(location: start + size, length: end - start - size))!
            let subrangeOld = Range(NSRange(location: start, length: end - start))!
            var zero: UInt = 0
            var commandData = Data()
            commandData.append(binary.subdata(in: subrangeNew))
            commandData.append(Data(bytes: &zero, count: size))

            binary.replaceSubrange(subrangeOld, with: commandData)
            binary.replaceSubrange(machoRange, with: newHeaderData)
            try FileManager.default.removeItem(at: url)
            try binary.write(to: url)
        }
    }

    static func injectNewCommand(_ url: URL) throws {
        var binary = try Data(contentsOf: url)
        let header = binary.extract(mach_header_64.self)

        var versionCommand = build_version_command(cmd: UInt32(LC_BUILD_VERSION),
                                                   cmdsize: 24,
                                                   platform: UInt32(PLATFORM_MACCATALYST),
                                                   minos: 0x000b0000,
                                                   sdk: 0x000e0000,
                                                   ntools: 0)

        let start = Int(header.sizeofcmds)+Int(MemoryLayout<mach_header_64>.size)
        let subData = binary[start..<start + Int(versionCommand.cmdsize)]

        var newheader = mach_header_64(magic: header.magic,
                                       cputype: header.cputype,
                                       cpusubtype: header.cpusubtype,
                                       filetype: header.filetype,
                                       ncmds: header.ncmds + 1,
                                       sizeofcmds: header.sizeofcmds + versionCommand.cmdsize,
                                       flags: header.flags,
                                       reserved: header.reserved)
        let newHeaderData = Data(bytes: &newheader, count: MemoryLayout<mach_header_64>.size)
        let machoRange = Range(NSRange(location: 0, length: MemoryLayout<mach_header_64>.size))!

        let testString = String(data: subData, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters)
        if testString != "" && testString != nil {
            print("Not enough space in binary!")
            return
        }

        var commandData = Data()
        commandData.append(Data(bytes: &versionCommand, count: MemoryLayout<build_version_command>.size))

        let subrange = Range(NSRange(location: start, length: commandData.count))!
        binary.replaceSubrange(subrange, with: commandData)

        binary.replaceSubrange(machoRange, with: newHeaderData)
        try FileManager.default.removeItem(at: url)
        try binary.write(to: url)
    }

    static func isMachoEncrypted(atURL url: URL) throws -> Bool {
        let binary = try Data(contentsOf: url)
        var header = binary.extract(fat_header.self)
        let offset = MemoryLayout.size(ofValue: header)
        let shouldSwap = header.magic == FAT_CIGAM

        if header.magic == FAT_MAGIC || header.magic == FAT_CIGAM {
            if shouldSwap {
                swap_fat_header(&header, NXHostByteOrder())
            }

            for _ in 0..<header.nfat_arch {
                var arch = binary.extract(fat_arch.self, offset: offset)
                if shouldSwap {
                    swap_fat_arch(&arch, 1, NXHostByteOrder())
                }

                if arch.cputype == CPU_TYPE_ARM64 {
                    return try isSlimMachoEncrypted(offset: Int(arch.offset), binary: binary)
                }
            }
        } else {
            return try isSlimMachoEncrypted(offset: 0, binary: binary)
        }

        return false
    }

    static func isSlimMachoEncrypted(offset: Int, binary: Data) throws -> Bool {
        var offset = offset
        var header = binary.extract(mach_header_64.self, offset: offset)
        offset += MemoryLayout.size(ofValue: header)
        let shouldSwap = header.magic == MH_CIGAM_64

        if shouldSwap {
            swap_mach_header_64(&header, NXHostByteOrder())
        }

        for _ in 0..<header.ncmds {
            var loadCommand = binary.extract(load_command.self, offset: offset)
            if shouldSwap {
                swap_load_command(&loadCommand, NXHostByteOrder())
            }

            switch loadCommand.cmd {
            case UInt32(LC_ENCRYPTION_INFO_64):
                var infoCommand = binary.extract(encryption_info_command_64.self, offset: offset)
                if shouldSwap {
                    swap_encryption_command_64(&infoCommand, NXHostByteOrder())
                }

                return infoCommand.cryptid != 0
            default:
                break
            }
            offset += Int(loadCommand.cmdsize)
        }

        return false
    }

    static func installedInExec(atURL url: URL) throws -> Bool {
        try stripBinary(url)
        let binary = try Data(contentsOf: url)
        var header = binary.extract(mach_header_64.self)
        var offset = MemoryLayout.size(ofValue: header)
        let shouldSwap = header.magic == MH_CIGAM_64

        if shouldSwap {
            swap_mach_header_64(&header, NXHostByteOrder())
        }

        for _ in 0..<header.ncmds {
            var loadCommand = binary.extract(load_command.self, offset: offset)
            if shouldSwap {
                swap_load_command(&loadCommand, NXHostByteOrder())
            }

            switch loadCommand.cmd {
            case UInt32(LC_LOAD_DYLIB):
                var dylibCommand = binary.extract(dylib_command.self, offset: offset)
                if shouldSwap {
                    swap_dylib_command(&dylibCommand, NXHostByteOrder())
                }

                let dylibName = String.init(data: binary,
                                            offset: offset,
                                            commandSize: Int(dylibCommand.cmdsize),
                                            loadCommandString: dylibCommand.dylib.name)
                if dylibName == playToolsPath.esc {
                    return true
                }
            default:
                break
            }
            offset += Int(loadCommand.cmdsize)
        }

        return false
    }

    static func isInstalled() throws -> Bool {
        try FileManager.default.fileExists(atPath: playToolsPath.path)
            && FileManager.default.fileExists(atPath: akInterfacePath.path)
            && isMachoValidArch(playToolsPath)
    }

    static func isMachoValidArch(_ url: URL) throws -> Bool {
        let binary = try Data(contentsOf: url)
        var header = binary.extract(fat_header.self)
        let offset = MemoryLayout.size(ofValue: header)
        let shouldSwap = header.magic == FAT_CIGAM

        if header.magic == FAT_MAGIC || header.magic == FAT_CIGAM {
            if shouldSwap {
                swap_fat_header(&header, NXHostByteOrder())
            }

            for _ in 0..<header.nfat_arch {
                var arch = binary.extract(fat_arch.self, offset: offset)
                if shouldSwap {
                    swap_fat_arch(&arch, 1, NXHostByteOrder())
                }

                if arch.cputype == CPU_TYPE_ARM64 {
                    return try isSlimMachoValidArch(offset: Int(arch.offset), binary: binary)
                }
            }
        } else {
            return try isSlimMachoValidArch(offset: 0, binary: binary)
        }

        return false
    }

    static func isSlimMachoValidArch(offset: Int, binary: Data) throws -> Bool {
        var offset = offset
        var header = binary.extract(mach_header_64.self, offset: offset)
        offset += MemoryLayout.size(ofValue: header)
        let shouldSwap = header.magic == MH_CIGAM_64

        if shouldSwap {
            swap_mach_header_64(&header, NXHostByteOrder())
        }

        for _ in 0..<header.ncmds {
            var loadCommand = binary.extract(load_command.self, offset: offset)
            if shouldSwap {
                swap_load_command(&loadCommand, NXHostByteOrder())
            }

            switch loadCommand.cmd {
            case UInt32(LC_BUILD_VERSION):
                var versionCommand = binary.extract(build_version_command.self, offset: offset)
                if shouldSwap {
                    swap_build_version_command(&versionCommand, NXHostByteOrder())
                }

                return versionCommand.platform == PLATFORM_MACCATALYST
            default:
                break
            }
            offset += Int(loadCommand.cmdsize)
        }

        return false
    }

	static func fetchEntitlements(_ exec: URL) throws -> String {
        do {
            return  try shell.sh("codesign --display --entitlements - --xml \(exec.path.esc)" +
                            " | xmllint --format -", pipeStdErr: false)
        } catch {
            if error.localizedDescription.contains("Document is empty") {
                // Empty entitlements
                return ""
            } else {
                throw error
            }
        }
	}
}
