# Review: src/interrupts.zig, as an adversary

This review covers `src/interrupts.zig`, the MSI-X routing in
`virtio.routeToProcessor`, and the callers that rest (`stream.zig`, `net.zig`,
`gopher.zig`'s `restBetweenFrames`). Nothing is fixed here. Each finding names
the failure it would cause and how likely that failure is. Findings are in
order of severity: what stops the machine first, then what slows it.

It is a reading, not a run. "Would" means the code allows the failure.
Whether a given host provokes it is noted where it is known.

## What holds up

These were checked and found sound, so the findings below are not about them:

- **The `sti; hlt; cli` window.**
  - `sti` takes effect after the next instruction, so an interrupt already
    pending in the local APIC is taken *at* the `hlt` and wakes it at once.
    A frame that arrives between "nothing yet" and the halt is not slept
    through.
  - After the handler's `iretq`, IF is 1 again until `cli`. A second pending
    interrupt can be taken in that gap, which is harmless because the
    handlers carry no work.
- **The handlers.**
  - `gm_irq` saves the only register it uses, and neither `movabs` nor `mov`
    touches the flags.
  - Kernel code has no red zone (`build.zig` sets `.red_zone = false`
    everywhere), so a frame pushed below `rsp` corrupts nothing.
  - Interrupt gates clear IF, so a handler is never interrupted.
- **The spurious vector.**
  - `0xFF` has its low four bits set, as older APICs require.
  - `gm_spurious` correctly does *not* write EOI: a spurious interrupt sets no
    in-service bit.
- **The timer.**
  - TSC-deadline mode is LVT timer bits 18:17 = `10b`, which is `2 << 17`.
  - The mode is set in `startApic`, before the first `rest` writes a deadline.
  - A deadline already in the past fires at once, so a slow path between the
    `wrmsr` and the `hlt` cannot make a rest unbounded.
- **The MSI-X message.**
  - Address `0xFEE0_0000 | id << 12` and data = vector give a fixed,
    edge-triggered message with a physical destination.
  - Entry 0's vector control is written last, after the address and data.
  - The function mask is cleared as MSI-X is enabled.
  - Each queue's vector is read back, which is how a device refuses
    (virtio §4.1.4.3).
- **Coalescing.** Two wake-ups that arrive while IF is 0 collapse into one
  IRR bit. Nothing is lost, because the work is found by looking, not by
  counting interrupts.

## Findings

### 1. The 8259 is masked but never remapped, and LINT0 still takes its interrupts: a spurious IRQ 7 stops the machine

**Where:** `startApic`, `port.outb(0x21, 0xFF); port.outb(0xA1, 0xFF)`.

**The problem:**

- The BIOS leaves the master PIC's vectors at `0x08`–`0x0F` and the local
  APIC's LINT0 in ExtINT (virtual-wire) mode.
- Masking with OCW1 stops new requests, but it does not stop the PIC's
  *spurious* IRQ 7. That interrupt is raised when an IRQ line drops between
  the request and the processor's acknowledge, and it is delivered even with
  every IRQ masked.
- The BIOS's 18.2 Hz tick (IRQ 0) can be mid-request at the moment of
  masking. If so, the processor's next acknowledge gets vector `0x08 + 7 =
  0x0F`.

**Failure:**

- Vector 15 goes to an exception stub. The machine prints `cpu exception
  15` with rip inside `rest`, and stops.
- The same stub path catches any other PIC interrupt that gets through, as
  exception 8–15. The comment in `startApic` already names vector 8, the
  double fault.

**How likely:** rare, timing-dependent, and once per boot at most, around
the first rest. It is fatal when it happens, and it would look like a
hardware fault.

**What a fix looks like:**

- Remap the PIC (ICW1–ICW4) to vectors at or above `0x20` before masking it,
  so anything it ever sends lands on `gm_irq` or `gm_spurious`.
- Mask LVT LINT0 (offset `0x350`, bit 16) so the PIC has no path in at all.
- Leave LINT1, the NMI, alone.

### 2. x2APIC mode is not checked: if the firmware enabled it, the machine halts forever

**Where:** `startApic` reads `IA32_APIC_BASE` and checks only the base
address (bits 12–31) before using the memory-mapped registers. Bit 10, x2APIC
enable, is never looked at.

**The problem:** in x2APIC mode the memory-mapped interface at
`0xFEE0_0000` is disabled (SDM §11.12). Every `lapicWrite` goes nowhere, and
that includes:

- SVR (the APIC software enable),
- the LVT timer,
- `gm_irq`'s EOI.

**Failure:**

- The APIC is never software-enabled, and the timer never runs. If an
  interrupt is delivered anyway, its EOI is lost and its in-service bit
  stays set. That blocks its own vector and every vector below it, and the
  wake and timer vectors are both priority class 4.
- `arm` is still called, so `rest` halts. Nothing wakes it: the machine
  stops answering, with nothing in the log.
- `lapicRead(lapic_id)` reads memory rather than the APIC, so the MSI-X
  message may also name the wrong processor.

**How likely:** low on the current path. Our own loader boots from legacy
BIOS (SeaBIOS on the droplet), which leaves xAPIC mode. UEFI firmware, and
hosts with more than 255 vCPUs, enable x2APIC. It matters the day the boot
path changes.

**Fix shape:** refuse (`Refusal.x2apic`) when bit 10 is set, or speak x2APIC
through MSRs `0x800+`. Either way, the check belongs next to the base-address
check.

### 3. The first TSC deadline may be written before the switch to TSC-deadline mode has taken effect

**Where:** `startApic` writes the LVT timer through MMIO; the first `rest`
writes `IA32_TSC_DEADLINE` with `wrmsr`.

**The problem:**

- The SDM (§11.5.4.1) warns that a write to the LVT timer through MMIO and a
  following `wrmsr` to `IA32_TSC_DEADLINE` are not ordered. A WRMSR to that
  MSR is one of the non-serializing ones.
- It recommends an `mfence` between the two.
- A deadline written while the timer is still in one-shot mode is ignored.

**Failure:**

- The first rest has no timer. It wakes only on a frame, so on a quiet
  network it sleeps until one arrives. Any TCP or stream timer due meanwhile
  waits with it.
- Every later `rest` writes a new deadline, so the effect is confined to the
  first rest.

**How likely:** low, and on a VM the LVT write traps, which orders it in
practice. It is cheap to rule out.

**Fix shape:** `mfence` after the LVT write in `startApic`.

### 4. A deadline that fired outside `rest` wakes the next rest at once

**Where:** `rest`. Each call writes a new deadline, but a rest that the card
ended early leaves the old deadline armed.

**The problem:**

- Suppose the deadline fires while the machine is working with IF 0.
- The timer interrupt then sits in the IRR.
- Writing a new deadline does not clear an interrupt that is already pending.

**Failure:** the next `rest` returns immediately. This costs one empty turn
of the loop, never correctness. Under steady traffic it happens about once
per `slice_ns` of work.

**How likely:** constant, and harmless. It is listed so that nobody reads a
too-early wake as a bug elsewhere.

**Fix shape (optional):** write `0` to `IA32_TSC_DEADLINE` (disarm) after
`hlt` returns. That does not clear an interrupt already pending in the IRR,
but it stops a stale deadline from firing later and waking a rest that
should have slept.

### 5. An NMI stops the machine

**Where:** `install` routes vector 2 to the same exception stub as faults,
and `gm_exception` always calls `serial.fail`.

**Failure:**

- An NMI is not an error in this machine: a hypervisor can inject one, for a
  watchdog or a console "inject NMI" action.
- Any NMI turns into "the processor stopped on an exception", ending the
  server.

**How likely:** rare on a droplet. It is listed because it is a choice made
by default rather than on purpose.

**Fix shape:** log vector 2 and return (`iretq`), or decide explicitly that
an NMI should stop the machine and say so in the comment.

### 6. Exceptions run on the faulting stack, with no IST

**Where:** every gate has `ist = 0`.

**The problem:** a fault caused by a bad `rsp` cannot push its frame. That
covers a corrupted stack pointer, or a frame that reaches unmapped memory
past `.bss`.

**Failure:** a double fault, then a triple fault and a reset. There is
nothing in the log, which is exactly what installing the IDT was meant to
end.

**How likely:** only after something else has already gone wrong. It
matters because it hides that other thing.

**Fix shape:**

- Load a TSS with one IST stack, and use it for vectors 8 (double fault) and
  2 (NMI).
- That needs a TSS descriptor in `boot.zig`'s GDT.

### 7. Queue vectors are set after the device is live

**Where:** `routeToProcessor` is called from `restBetweenFrames`. That is
after `Net.init` has enabled both queues and set DRIVER_OK, and after DHCP.

**The problem:** virtio §4.1.5.1.2 describes setting `queue_msix_vector`
while setting up each queue, before it is enabled. Setting it later works on
QEMU, which re-reads it on every notification.

**Failure:**

- A device that reads it only at enable time keeps using no vector. The
  read-back would then say success while no interrupt ever comes.
- `rest` would then be bounded only by the 1 ms timer: correct, but
  never resting for less than a whole slice after a frame.

**How likely:** none on QEMU or the droplet as it is today. It is a
portability risk.

**Fix shape:** route during `Net.init`, before `queue_enable`. MSI-X must
then be configured before the queues come up.

### 8. Every frame sent reads the ISR, which MSI-X makes pointless

**Where:** `Net.send` and `Net.poll` call `virtio.ack`, and on PCI that reads
the ISR status register.

**The problem:** with MSI-X enabled, queue interrupts never set the ISR
(virtio §4.1.4.5), so the read does nothing. But on a VM every read of
device memory is a trip to the hypervisor.

**Failure:** none. It costs one extra exit per frame sent and per frame
received, and on the droplet those exits are the cost being measured.

**Fix shape:** skip `ack` once `routeToProcessor` has succeeded.

### 9. The APIC page's cache type is left to the firmware

**Where:** `boot.zig` maps the low 4 GB with 2 MB pages, present and
writable (`0x83`), with no PCD/PWT. The APIC page and the MSI-X table are
both in that map.

**The problem:** the effective memory type is uncachable only because the
firmware's MTRRs mark the PCI hole as UC. SeaBIOS does. A firmware that
does not would leave register writes cacheable. On real hardware that
means:

- an EOI that is not seen,
- MSI-X table writes that never reach the device.

**How likely:** none under SeaBIOS or KVM, where APIC accesses trap
regardless of type. Bare metal with other firmware is the risk.

**Fix shape:** map `0xC000_0000` and above with PCD set, so the device
windows are uncachable whatever the MTRRs say.

## Suggested order, when fixing

1. **#1, the remap and LINT0 mask:** fatal, cheap, and local to
   `startApic`.
2. **#2, the x2APIC refusal:** one more check where the others are.
3. **#3, the `mfence`:** one instruction.
4. **#6, an IST for #DF and NMI**, together with a decision on **#5**.
5. **#7, #8 and #9**, when the driver is touched next. #7 and #8 are in
   `src/virtio.zig`, which is being reworked for the SCSI volume.
6. **#4** needs nothing unless the early wakes are measured to matter.
