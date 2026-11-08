@ =============================================================================
@  display-probe/probe.S  --  EC6108V9C "contact-boot visual probe"
@ =============================================================================
@  WHAT THIS IS
@  A tiny ARMv7-A bare-metal program that is NOT a bootloader and does NOT
@  flash anything. It is loaded into RAM by the community fastboot.bin through
@  its bootargs.bin bootcmd:
@      fatload usb 0 0x01000000 display.bin; go 0x01000000
@  and then paints a growing green progress bar into the DRAM regions that a
@  mainline "mem=1G" boot uses as framebuffer / reserve memory.
@
@  PURPOSE (phase 1 of the boot/flash-display goal)
@  Answer ONE question on real hardware: during the shorted "flash" boot,
@  is the VO/HDMI output alive and scanning one of these DRAM regions?
@    - If the screen shows a growing green bar -> VO is scanning this DRAM,
@      so a real progress bar in the flash program needs NO p1 change, NO
@      image assets, NO HDMI init: just write pixels here. DONE.
@    - If the screen stays black -> this branch has no HDMI signal at all;
@      the next iteration adds the VO/HDMI/PHY init sequence from docs/035
@      and the SDK sources before painting.
@    - If a garbled / partial colour field appears -> address is right but
@      stride / geometry is off; tune FB geometry, display still proven.
@
@  SAFETY
@  - DDR writes ONLY. No MMIO register writes, no clock/reset/PHY touching,
@    no eMMC writes, no partition changes, no reset. Always re-flashable.
@  - All target addresses are well inside DDR (mem=1G -> top 0x40000000) and
@    far below the top edge; each region is painted 1 MiB only, no wraparound.
@  - Loaded at 0x01000000, far from fastboot.bin (0x00C00000) and its stack.
@
@  LINK / LOAD
@    clang --target=armv7-none-eabi -c probe.S -o probe.o
@    ld.lld --oformat=binary -Ttext=0x01000000 probe.o -o display.bin
@  The flat binary starts with the first instruction of _start; `go` jumps
@  straight there (ARM state even address). No reset vector table needed.
@ =============================================================================

    .syntax unified
    .arch armv7-a
    .arm
    .text
    .global _start

    .equ WORDS,      0x40000      @ 1 MiB of ARGB8888 pixels = 262144 words
    .equ STEP,       0x2000       @ progress-bar growth per frame (words)
    .equ NB,         4            @ number of candidate framebuffer regions
    .equ C_DONE,     0xFF00FF00   @ opaque bright green  (progress "done")
    .equ C_TODO,     0xFF102040   @ opaque deep blue     (progress "todo")
    .equ DELAY,      0x400000     @ inter-frame busy-wait

_start:
    cpsid aif                     @ mask async-abort/IRQ/FIQ: `go` leaves us
                                  @ with no vector table at this load address,
                                  @ so a stray interrupt must not be taken
    ldr  r12, =block_table        @ r12 = candidate region table (constant)
    mov  r11, #NB                 @ r11 = region count (constant)
    ldr  r6,  =WORDS             @ r6  = words per region (constant)
    ldr  r3,  =C_DONE            @ r3  = green (constant)
    ldr  r4,  =C_TODO            @ r4  = deep blue (constant)
    mov  r10, #0                  @ r10 = progress (words), 0 .. WORDS

frame_loop:
    mov  r9, #0                  @ r9 = region index

region_loop:
    ldr  r0, [r12, r9, lsl #2]   @ r0 = region physical base
    mov  r1, #0                  @ r1 = word index within region
    mov  r2, r10                 @ r2 = progress boundary for this frame

paint_loop:
    cmp  r1, r2
    movlo r5, r3                 @ below boundary  -> green  (done)
    movhs r5, r4                 @ above boundary  -> blue   (todo)
    str  r5, [r0, r1, lsl #2]   @ write one ARGB8888 pixel
    add  r1, r1, #1
    cmp  r1, r6
    blo  paint_loop

    add  r9, r9, #1
    cmp  r9, r11
    blo  region_loop

    @ advance the progress bar, wrap to 0 at the end -> continuous animation
    add  r10, r10, #STEP
    cmp  r10, r6
    movhs r10, #0

    @ short busy-wait so the bar is watchable instead of a blur
    ldr  r7, =DELAY
delay_loop:
    subs r7, r7, #1
    bne  delay_loop

    b    frame_loop

    .ltorg

    .align 2
@ Candidate scan-out / reserve physical addresses. Sources:
@   0x3FBFD000  4 MiB reserve block, mem=1G "Reserve Memory" log (docs/048)
@   0x3F8FC000  3 MiB reserve block, mem=1G "Reserve Memory" log (docs/048)
@   0x3F6CE000  HIFB_DispBuf_HD VO layer0 buffer (docs/041)
@   0x3C55C000  community Linux /dev/fb0 smem_start (docs/040)
@ Painting all four maximises the chance of hitting whichever buffer the VO
@ happens to be scanning in this boot branch. 1 MiB each stays inside DDR.
block_table:
    .word 0x3FBFD000
    .word 0x3F8FC000
    .word 0x3F6CE000
    .word 0x3C55C000

    .end
