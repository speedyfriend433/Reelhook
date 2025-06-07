// SwiftReel.swift

import Foundation
import MachO

#if arch(x86_64) || arch(arm64)
private typealias mach_header_t = mach_header_64
private typealias segment_command_t = segment_command_64
private typealias section_t = section_64
private typealias nlist_t = nlist_64
private let LC_SEGMENT_TYPE = UInt32(LC_SEGMENT_64)
#else
private typealias mach_header_t = mach_header
private typealias segment_command_t = segment_command
private typealias section_t = section
private typealias nlist_t = nlist
private let LC_SEGMENT_TYPE = UInt32(LC_SEGMENT)
#endif

public struct Rebinding {
    let name: String
    let replacement: UnsafeMutableRawPointer
    let original: UnsafeMutablePointer<UnsafeMutableRawPointer?>?

    public init(name: String,
                replacement: UnsafeMutableRawPointer,
                original: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) {
        self.name = name
        self.replacement = replacement
        self.original = original
    }
}

public func rebindSymbols(_ rebindings: [Rebinding]) {
    for i in 0..<_dyld_image_count() {
        guard let header = _dyld_get_image_header(i) else { continue }
        let slide = _dyld_get_image_vmaddr_slide(i)
        performRebinding(for: header, slide: slide, rebindings: rebindings)
    }
}

private func performRebinding(for header: UnsafePointer<mach_header_t>, slide: Int, rebindings: [Rebinding]) {
    var symtabCmd: UnsafePointer<symtab_command>?
    var dysymtabCmd: UnsafePointer<dysymtab_command>?
    var linkeditSegment: UnsafePointer<segment_command_t>?
    let firstCmd = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_t>.size)
    var currentCmd = firstCmd

    for _ in 0..<header.pointee.ncmds {
        let cmd = currentCmd.assumingMemoryBound(to: load_command.self)

        if cmd.pointee.cmd == LC_SYMTAB {
            symtabCmd = UnsafePointer(currentCmd.assumingMemoryBound(to: symtab_command.self))
        } else if cmd.pointee.cmd == LC_DYSYMTAB {
            dysymtabCmd = UnsafePointer(currentCmd.assumingMemoryBound(to: dysymtab_command.self))
        } else if cmd.pointee.cmd == LC_SEGMENT_TYPE {
            let segment = currentCmd.assumingMemoryBound(to: segment_command_t.self)
            if let segname = String(cString: &segment.pointee.segname.0, maxLength: 16), segname == SEG_LINKEDIT {
                linkeditSegment = segment
            }
        }
        currentCmd = currentCmd.advanced(by: Int(cmd.pointee.cmdsize))
    }
    guard let symtabCmd = symtabCmd,
          let dysymtabCmd = dysymtabCmd,
          let linkeditSegment = linkeditSegment else {
        return
    }
    let linkeditBase = slide + Int(linkeditSegment.pointee.vmaddr) - Int(linkeditSegment.pointee.fileoff)
    let symtab = UnsafePointer<nlist_t>(bitPattern: linkeditBase + Int(symtabCmd.pointee.symoff))!
    let strtab = UnsafePointer<CChar>(bitPattern: linkeditBase + Int(symtabCmd.pointee.stroff))!
    let indirectSymtab = UnsafePointer<UInt32>(bitPattern: linkeditBase + Int(dysymtabCmd.pointee.indirectsymoff))!

    currentCmd = firstCmd
    for _ in 0..<header.pointee.ncmds {
        let cmd = currentCmd.assumingMemoryBound(to: load_command.self)
        
        if cmd.pointee.cmd == LC_SEGMENT_TYPE {
            let segment = currentCmd.assumingMemoryBound(to: segment_command_t.self)
            let firstSection = UnsafeRawPointer(segment).advanced(by: MemoryLayout<segment_command_t>.size)
            var currentSection = firstSection.assumingMemoryBound(to: section_t.self)
            
            for _ in 0..<segment.pointee.nsects {
                let section = currentSection
                let sectionType = section.pointee.flags & SECTION_TYPE
                if sectionType == S_LAZY_SYMBOL_POINTERS || sectionType == S_NON_LAZY_SYMBOL_POINTERS {

                    let pointerSize = MemoryLayout<UnsafeMutableRawPointer>.size
                    let numPointersInSection = Int(section.pointee.size) / pointerSize
                    let indirectSymStartIndex = Int(section.pointee.reserved1)
                    guard let sectionPointers = UnsafeMutablePointer<UnsafeMutableRawPointer?>(bitPattern: slide + Int(section.pointee.addr)) else { continue }
                    
                    for i in 0..<numPointersInSection {
                      
                        let indirectSymIndex = indirectSymtab[indirectSymStartIndex + i]
                        let symtabIndex = Int(indirectSymIndex)
                        let symbol = symtab[symtabIndex]
                        let symbolNamePtr = strtab.advanced(by: Int(symbol.n_un.n_strx))
                        let symbolName = String(cString: symbolNamePtr)
                        
                        if symbolName.isEmpty { continue }
                        let symbolNameToMatch = symbolName.hasPrefix("_") ? String(symbolName.dropFirst()) : symbolName
                        
                        for rebinding in rebindings where rebinding.name == symbolNameToMatch {
                            let pointerToPatch = sectionPointers.advanced(by: i)
                            
                            if pointerToPatch.pointee != rebinding.replacement {
                                if let original = rebinding.original {
                                    original.pointee = pointerToPatch.pointee
                                }
                                pointerToPatch.pointee = rebinding.replacement
                            }
                            break
                        }
                    }
                }
                currentSection = currentSection.advanced(by: 1)
            }
        }
        currentCmd = currentCmd.advanced(by: Int(cmd.pointee.cmdsize))
    }
}

private extension String {
    init(cString: UnsafePointer<CChar>, maxLength: Int) {
        self = cString.withMemoryRebound(to: UInt8.self, capacity: maxLength) {
            String(cString: $0)
        }
    }
}
