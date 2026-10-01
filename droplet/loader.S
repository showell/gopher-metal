# **THE BOOT LOADER: FROM A BIOS TO gopher-metal'S PVH ENTRY.**
#
# A droplet starts the way a 1990s PC did: the BIOS reads the disk's first
# sector to 0x7C00 and runs it in 16-bit real mode. gopher-metal's kernels
# expect what QEMU's PVH loader and metal-vmm give them instead: their
# segments already in memory, a memory map, and a jump to the 32-bit entry
# with %ebx pointing at a `hvm_start_info`. This file is the bridge, and it
# does exactly that, using the BIOS for the two things only it can do here:
# read the disk (int 13h) and say where the RAM is (int 15h, E820).
#
# Two stages, because one sector is not enough:
#   stage 1  the first 432 bytes of sector 0. Reads stage 2 from LBA 34 (just
#            past the GPT's table) to 0x7E00, right behind itself.
#   stage 2  everything after the first 512 bytes of this file.
#
# **WHAT THE IMAGE BUILDER WRITES, AND WHERE** (droplet/image.zig):
#   offset 432 of sector 0   the kernel partition's first LBA (`kernel_lba`)
#   offsets 440-511          the protective MBR's partition table and the
#                            boot signature, around this code
#   the kernel partition     sector 0 is a header (below); each segment's
#                            bytes follow, starting on a sector
#
# The header: "GMKERNEL", the PVH entry (u32), the segment count (u32), then
# per segment the physical address, its first sector relative to the
# partition, its size in the file and its size in memory (four u32s).
#
# Memory this uses, all below the kernel's 1 MB:
#   0x6000  the hvm_start_info       0x6100  its memory map (64 entries max)
#   0x6800  the kernel header        0x7C00  this code; the stack grows down
#   0x10000 a 32 KB bounce buffer: the BIOS reads there, then it is copied up
#
# Every message goes to COM1 AND the screen, because DigitalOcean's recovery
# console shows the screen and nothing else.

    .code16
    .text
    .globl _start
_start:
    cli
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov $0x7C00, %sp
    ljmp $0, $1f                    # some BIOSes arrive at 07C0:0000
1:  sti
    cld
    mov $'G', %al
    call mark
    mov %dl, boot_drive             # the BIOS says which disk it booted
    mov $msg_hello, %si
    call say
    movw $stage2_sectors, dap_count
    movw $0x7E00, dap_offset
    movw $0, dap_segment
    movl $34, dap_lba
    call read_disk
    jmp stage2

# Prints the NUL-terminated string at %ds:%si.
say:
    pusha
2:  lodsb
    test %al, %al
    jz 3f
    call putc
    jmp 2b
3:  popa
    ret

# **WHERE THE LOADER IS, WITH NOTHING BETWEEN IT AND THE SCREEN**: the
# character in %al, white on green, in the top-right corner, written straight
# into text memory. G: stage 1 runs; S: stage 2 runs; K: about to jump to the
# kernel. On a droplet whose screen shows nothing else, the corner says how
# far it got.
mark:
    push %es
    push %bx
    mov $0xB800, %bx
    mov %bx, %es
    mov $0x2F, %ah
    mov %ax, %es:158                # row 0, column 79
    pop %bx
    pop %es
    ret

# One character, to the screen and then to COM1. **THE SCREEN FIRST, AND THE
# SERIAL PORT NEVER WAITED ON FOR LONG**: a port whose transmitter never
# empties (nothing reads it) must not hang the loader before anything is
# shown. After 65,536 not-ready reads the port is given up on for the rest of
# the boot.
putc:
    pusha
    mov %al, %cl
    mov $0x0E, %ah                  # the BIOS's teletype: page 0, grey
    mov $0x0007, %bx
    int $0x10
    cmpb $0, serial_dead
    jne 5f
    mov $0x3FD, %dx                 # line status: wait for the transmitter
    xor %bx, %bx
4:  in %dx, %al
    test $0x20, %al
    jnz 6f
    dec %bx
    jnz 4b
    movb $1, serial_dead
    jmp 5f
6:  mov $0x3F8, %dx
    mov %cl, %al
    out %al, %dx
5:  popa
    ret

# Reads what `dap` describes. A failure is the end of the boot.
read_disk:
    pushal
    mov $dap, %si
    mov boot_drive, %dl
    mov $0x42, %ah                  # extended read, by LBA
    int $0x13
    jc disk_failed
    popal
    ret
disk_failed:
    mov $msg_disk, %si
    call say
stop:
    cli
    hlt
    jmp stop

boot_drive: .byte 0
serial_dead: .byte 0
    .balign 4
dap:                                # the disk address packet int 13h reads
    .byte 16, 0
dap_count:   .word 0
dap_offset:  .word 0
dap_segment: .word 0
dap_lba:     .quad 0

msg_hello: .asciz "gopher-metal loader\r\n"
msg_disk:  .asciz "FAIL: the disk would not read\r\n"

    .org 432                        # stage 1 must end before this field
kernel_lba: .long 0
    .org 510
    .word 0xAA55

# ── stage 2 ──────────────────────────────────────────────────────────────────
stage2:
    mov $'S', %al
    call mark
    mov $msg_stage2, %si
    call say
    call enable_a20

    # The kernel's header, through the bounce buffer to where it stays.
    mov kernel_lba, %eax
    mov %eax, dap_lba
    movw $1, dap_count
    movw $0, dap_offset
    movw $0x1000, dap_segment
    call read_disk
    push %ds
    mov $0x1000, %ax
    mov %ax, %ds
    xor %si, %si
    mov $0x6800, %di
    mov $512, %cx
    rep movsb
    pop %ds
    mov $0x6800, %si
    mov $magic, %di
    mov $8, %cx
    repe cmpsb
    jne not_a_kernel

    mov 0x680C, %eax
    mov %eax, segs_left
    movw $0x6810, seg_ptr

next_segment:
    cmpl $0, segs_left
    je segments_done
    mov seg_ptr, %bx
    mov 0(%bx), %eax
    mov %eax, dest
    mov 4(%bx), %eax
    add kernel_lba, %eax
    mov %eax, next_lba
    mov 8(%bx), %eax
    mov %eax, remaining
    mov 12(%bx), %eax
    sub 8(%bx), %eax
    mov %eax, zeroes

next_chunk:
    mov remaining, %eax
    test %eax, %eax
    jz zero_the_rest
    add $511, %eax                  # sectors still to read, at most 64
    shr $9, %eax
    cmp $64, %eax
    jbe 5f
    mov $64, %eax
5:  mov %ax, dap_count
    movw $0, dap_offset
    movw $0x1000, dap_segment
    mov next_lba, %edx
    mov %edx, dap_lba
    add %eax, next_lba
    call read_disk
    shl $9, %eax                    # bytes read, but no more than remain
    cmp remaining, %eax
    jbe 6f
    mov remaining, %eax
6:  sub %eax, remaining
    mov %eax, %ecx
    call unreal
    mov $0x10000, %esi
    mov dest, %edi
    add %ecx, dest
    addr32 rep movsb                # past 1 MB: %esi and %edi are 32-bit
    jmp next_chunk

# **.bss IS NOT IN THE FILE**: what a segment holds beyond its file size is
# memory the kernel owns, and it is handed over zeroed, as QEMU's loader and
# metal-vmm hand it over. A fresh machine's memory is already zero, so
# boot.sh starts every probe on RAM full of 0xA5: without the `rep stosb`
# below, the clock probe fails there.
zero_the_rest:
    mov zeroes, %ecx
    call unreal
    mov dest, %edi
    xor %al, %al
    addr32 rep stosb
    addw $16, seg_ptr
    decl segs_left
    jmp next_segment

segments_done:
    mov $msg_loaded, %si
    call say

    # **THE MEMORY MAP, FROM THE BIOS.** E820 entries are 24 bytes (base,
    # length, type, extended attributes); PVH's are 24 bytes too (address,
    # size, type, reserved), so each lands in place and only the last word is
    # cleared. A zero-length entry is skipped.
    xor %ebx, %ebx
    mov $0x6100, %di
    xor %bp, %bp
e820:
    movl $1, 20(%di)
    mov $0xE820, %eax
    mov $24, %ecx
    mov $0x534D4150, %edx           # "SMAP"
    int $0x15
    jc e820_end
    cmp $0x534D4150, %eax
    jne no_memory_map
    movl $0, 20(%di)
    mov 8(%di), %eax
    or 12(%di), %eax
    jz 7f
    add $24, %di
    inc %bp
    cmp $64, %bp
    je e820_end
7:  test %ebx, %ebx
    jnz e820
e820_end:
    test %bp, %bp
    jz no_memory_map

    # The hvm_start_info: magic, version 1, and the map. Everything else zero.
    mov $0x6000, %di
    mov $14, %cx                    # 56 bytes
    xor %eax, %eax
    rep stosl
    movl $0x336EC578, 0x6000        # PVH's magic
    movl $1, 0x6004                 # version 1: the one with a memory map
    movl $0x6100, 0x6028            # memmap_paddr (byte 40)
    mov %bp, 0x6030                 # memmap_entries (byte 48)
    mov $msg_start, %si
    call say
    mov $'K', %al
    call mark

    # **INTO 32-BIT PROTECTED MODE, AS PVH STARTS A KERNEL**: flat segments,
    # paging off, interrupts off, %ebx at the start_info.
    cli
    lgdt gdt_descriptor
    mov %cr0, %eax
    or $1, %al
    mov %eax, %cr0
    ljmp $0x08, $protected

not_a_kernel:
    mov $msg_not_kernel, %si
    call say
    jmp stop
no_memory_map:
    mov $msg_no_map, %si
    call say
    jmp stop

# **UNREAL MODE**: load a 4 GB limit into %ds and %es from protected mode,
# then come straight back. Real mode keeps the limit, so `addr32` copies reach
# past 1 MB while the BIOS stays callable. Done before every copy, because a
# BIOS call may put the 64 KB limits back.
unreal:
    push %eax
    push %bx
    cli
    lgdt gdt_descriptor
    mov %cr0, %eax
    or $1, %al
    mov %eax, %cr0
    mov $0x10, %bx
    mov %bx, %ds
    mov %bx, %es
    and $0xFE, %al
    mov %eax, %cr0
    xor %bx, %bx
    mov %bx, %ds
    mov %bx, %es
    sti
    pop %bx
    pop %eax
    ret

# The A20 line: without it, address bit 20 is forced to zero and the kernel's
# 1 MB lands on top of 0. The BIOS's way first, then the chipset's port.
enable_a20:
    mov $0x2401, %ax
    int $0x15
    in $0x92, %al
    or $2, %al
    and $0xFE, %al
    out %al, $0x92
    ret

    .code32
protected:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %fs
    mov %ax, %gs
    mov %ax, %ss
    mov $0x7C00, %esp
    mov $0x6000, %ebx
    mov 0x6808, %eax                # the PVH entry, from the header
    jmp *%eax
    .code16

    .balign 8
gdt:
    .quad 0
    .quad 0x00CF9A000000FFFF        # 0x08: code, flat 4 GB, 32-bit
    .quad 0x00CF92000000FFFF        # 0x10: data, flat 4 GB
gdt_descriptor:
    .word gdt_descriptor - gdt - 1
    .long gdt

    .balign 4
segs_left: .long 0
seg_ptr:   .word 0
dest:      .long 0
next_lba:  .long 0
remaining: .long 0
zeroes:    .long 0

magic:          .ascii "GMKERNEL"
msg_stage2:     .asciz "  reading the kernel\r\n"
msg_loaded:     .asciz "  kernel in memory\r\n"
msg_start:      .asciz "  starting it\r\n"
msg_not_kernel: .asciz "FAIL: the kernel partition has no GMKERNEL header\r\n"
msg_no_map:     .asciz "FAIL: the BIOS gave no memory map\r\n"

stage2_end:
    .set stage2_sectors, (stage2_end - stage2 + 511) / 512
