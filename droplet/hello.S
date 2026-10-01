# **THE SMALLEST THING A DROPLET CAN BOOT.** A BIOS reads the disk's first
# sector to 0x7C00 and jumps to it in 16-bit real mode, and that is all this
# is: one line on COM1, then the exit door. It proves the path a custom image
# takes (BIOS, disk, first sector) before anything of ours stands on it.
#
# The exit door (0xF4) is QEMU's test device and is absent on a real droplet,
# where the write goes nowhere and the loop below holds the processor.
    .code16
    .text
    .globl _start
_start:
    cli
    xor %ax, %ax
    mov %ax, %ds
    mov $message, %si
next:
    lodsb
    test %al, %al
    jz done
    mov %al, %bl
    mov $0x3FD, %dx    # line status: wait for the transmitter
wait:
    in %dx, %al
    test $0x20, %al
    jz wait
    mov $0x3F8, %dx
    mov %bl, %al
    out %al, %dx
    jmp next
done:
    xor %al, %al
    out %al, $0xF4    # exit 0
halt:
    hlt
    jmp halt

message:
    .asciz "gopher-metal droplet: booted from the disk's first sector\r\n"

    .org 510
    .word 0xAA55
