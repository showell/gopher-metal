/* The probe kernel's layout.

   The PVH note has to be a real SHT_NOTE section inside a PT_NOTE segment,
   because that is what QEMU scans to find the 32-bit entry point. It is KEPT
   because nothing references it and the linker would otherwise be right to
   drop it. `:text :note` puts the one section in both segments: loaded with
   everything else, and findable as a note.

   1 MB is where codex-vm loads a Codex kernel and where a loader will happily
   put this one. Nothing below it is ours. */
ENTRY(_start)

PHDRS {
    text PT_LOAD FLAGS(7);
    note PT_NOTE FLAGS(4);
}

SECTIONS {
    . = 1M;
    /* Where this kernel's image begins and ends. The page allocator hands out
       the machine's RAM, and the machine's RAM includes the bytes this kernel
       is sitting in — so it has to know which those are. `_kernel_end` is after
       .bss, because .bss is memory the kernel owns even though the file does
       not carry it. */
    _kernel_start = .;

    .note.Xen : { KEEP(*(.note.Xen)) } :text :note
    .text     : { *(.text*) } :text
    .rodata   : { *(.rodata*) } :text
    .data     : { *(.data*) } :text

    /* .bss is NOBITS: the loader does not write it, so nothing here may be
       assumed zero. The page tables live in .data for exactly that reason. */
    .bss      : { *(.bss*) *(COMMON) } :text
    _kernel_end = .;

    /DISCARD/ : { *(.eh_frame) *(.comment) *(.note.GNU-stack) }
}
