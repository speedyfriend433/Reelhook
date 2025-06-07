// reel.c

#include "reel.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#ifdef __LP64__
  typedef struct mach_header_64 mach_header_t;
  typedef struct segment_command_64 segment_command_t;
  typedef struct section_64 section_t;
  typedef struct nlist_64 nlist_t;
  #define LC_SEGMENT_TYPE LC_SEGMENT_64
#else
  typedef struct mach_header mach_header_t;
  typedef struct segment_command segment_command_t;
  typedef struct section section_t;
  typedef struct nlist nlist_t;
  #define LC_SEGMENT_TYPE LC_SEGMENT
#endif

static void _perform_rebinding_for_image(const mach_header_t *header,
                                         intptr_t vmaddr_slide,
                                         struct rebinding rebindings[],
                                         size_t rebindings_count) {

    segment_command_t *cur_seg_cmd;
    struct symtab_command *symtab_cmd = NULL;
    struct dysymtab_command *dysymtab_cmd = NULL;
  
    uintptr_t cur = (uintptr_t)header + sizeof(mach_header_t);
    for (uint32_t i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
        cur_seg_cmd = (segment_command_t *)cur;
        if (cur_seg_cmd->cmd == LC_SYMTAB) {
            symtab_cmd = (struct symtab_command *)cur;
        } else if (cur_seg_cmd->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (struct dysymtab_command *)cur;
        }
    }
    if (!symtab_cmd || !dysymtab_cmd) {
        return;
    }
    uintptr_t symtab_base = vmaddr_slide + symtab_cmd->symoff;
    uintptr_t strtab_base = vmaddr_slide + symtab_cmd->stroff;
    uint32_t *indirect_sym_indices = (uint32_t *)(vmaddr_slide + dysymtab_cmd->indirectsymoff);

    cur = (uintptr_t)header + sizeof(mach_header_t);
    for (uint32_t i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
        cur_seg_cmd = (segment_command_t *)cur;
        if (cur_seg_cmd->cmd == LC_SEGMENT_TYPE) {
            section_t *sections = (section_t *)((uintptr_t)cur_seg_cmd + sizeof(segment_command_t));
            for (uint32_t j = 0; j < cur_seg_cmd->nsects; j++) {
                section_t *sect = §ions[j];
                
                uint8_t type = sect->flags & SECTION_TYPE;
                if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS) {
                    uint32_t start_index = sect->reserved1;
                    uint32_t num_pointers = (uint32_t)(sect->size / sizeof(void*));

                    for (uint32_t k = 0; k < num_pointers; k++) {
                        uint32_t sym_idx = indirect_sym_indices[start_index + k];
                        nlist_t *symbol = &((nlist_t *)symtab_base)[sym_idx];
                        char *symbol_name = (char *)strtab_base + symbol->n_un.n_strx;
                        
                        for (size_t l = 0; l < rebindings_count; l++) {
                            if (strcmp(&symbol_name[1], rebindings[l].name) == 0) {
                                void **lazy_ptr = (void **)(vmaddr_slide + sect->addr + k * sizeof(void*));
                                void *original_impl = *lazy_ptr;
                                
                                if (original_impl != rebindings[l].replacement) {
                                    if (rebindings[l].original != NULL) {
                                        *(rebindings[l].original) = original_impl;
                                    }
                                    *lazy_ptr = rebindings[l].replacement;
                                }
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
}


int rebind_symbols(struct rebinding rebindings[], size_t rebindings_count) {
    uint32_t image_count = _dyld_image_count();
    for (uint32_t i = 0; i < image_count; i++) {
        const mach_header_t *header = (const mach_header_t *)_dyld_get_image_header(i);
        intptr_t vmaddr_slide = _dyld_get_image_vmaddr_slide(i);
        
        _perform_rebinding_for_image(header, vmaddr_slide, rebindings, rebindings_count);
    }
    return 0;
}
