# The SPCP6651B config protocol

How the 2E MG330 (USB `1BCF:08B8`, Sunplus SPCP6651B) is configured, recovered from the
vendor's Windows driver and then checked against a live mouse.

Source material: `2E-MG330-V3.0.exe` from 2egaming.com, an NSIS installer. Inside it are
`2E-MG330.exe` (an MFC app), `SunplusIT_6651.dll` (99 KB, PE x86 — all the device I/O) and
`SPCP6651BData_Cfg1.bin`, a 2 KB factory config image whose first four bytes are
`1b cf 08 b8`, the VID and PID. The DLL was decompiled with Ghidra.

Everything below that is called *confirmed* was reproduced on a real mouse.

## Transport

The Windows driver calls `HidD_SetFeature` / `HidD_GetFeature`, so every transfer is an
8-byte HID **feature report**. On macOS the same channel is reachable through
`IOHIDDeviceSetReport` / `IOHIDDeviceGetReport` with `kIOHIDReportTypeFeature`.

Two report IDs are used: `0x40` carries commands, `0x41` carries bulk data.

| Operation | Report | Bytes |
|---|---|---|
| write 1–3 bytes | `0x40` Set | `40 05 00 ADDR v0 v1 v2 COUNT` |
| block read | `0x40` Set | `40 09 addrHi addrLo lenHi lenLo 00 00` |
| …then, per 7 bytes | `0x41` Get | report ID in byte 0, 7 data bytes in 1…7 |
| block write | `0x40` Set | `40 07 addrHi addrLo lenHi lenLo 00 00` |
| …then, per 7 bytes | `0x41` Set | 7 data bytes |
| register write | `0x40` Set | `40 01 07 REG VALUE 00` |
| reload firmware | `0x40` Set | `40 0e 00 00 00 00 00 00` |

The single-byte write primitive is `FUN_10006920` in the DLL, which builds
`[0x40, 0x05, 0x00, addr, b0, b1, b2, count]` and is called from 48 places — it is the
workhorse behind nearly every setter. `FUN_100069c0` is the generic form used for the
block headers and for the register writes.

### Opening the device on macOS

A plain `IOHIDDeviceOpen` is enough; `kIOHIDOptionsTypeSeizeDevice` is actually *refused*
here with `kIOReturnNotPrivileged`. Not seizing means the mouse keeps working as a mouse
while a tool is talking to it. The process must still hold Input Monitoring, as any HID
access on macOS does.

## The config image

The device holds 2 KB of configuration, addressed directly by the write primitive. In the
DLL this lives at `this+0x1405`, so a field at `this+X` is device address `X - 0x1405`.
Addresses themselves come from a lookup table built by `FUN_100044f0` at `this+0x156c`;
index `(field - 0x156c) / 4` gives the device address.

| Address | Meaning |
|---|---|
| `0x04` | polling rate bits 4 and 5 |
| `0x08` | polling rate bit 3 |
| `0x2B` | DPI gear count, stored as `count - 1` |
| `0x2C`–`0x2F` | DPI steps, two 4-bit gears per byte (even gear low nibble) |
| `0x39` + 3·n | user palette, 10 colours — drives the logo zone |
| `0x57` + 3·n | per-gear indicator colours, 8 entries |
| `0x6F` | product name, NUL-terminated ASCII |
| `0xA3` | checksum over `0x00`–`0xA2` |
| `0xA5` | LED effect: stored as `effect + 0x81`, bit 7 = lights on |
| `0xA6` | active gear, 0-based |
| `0xA4`, `0xA7`–`0xAA` | written by `Set_Key_Mode`; meaning not traced |
| `0xC0`, `0xF1`, `0x122` | three button profiles, 12 slots × 4 bytes + checksum at +0x30 |
| `0x3E8` | LED mode data block, 8 bytes |
| `0x3F0` | LED breath block, 16 bytes, own checksum in the last byte |

### Checksums

Every checksummed region follows one rule, from `FUN_10006530` and `FUN_100066d0`:

```
checksum = (sum of the bytes in the region) XOR 0x5A
```

**Confirmed.** Reading a live config image back and recomputing gives the stored value for
all five regions at once: the main config, each of the three button profiles, and the
breath block. That agreement is what pins the table above.

The firmware does **not** maintain these itself when you use the single-byte write
command — the vendor driver recomputes them before each block write. Leaving a stale
checksum risks the mouse treating its config as corrupt, so a tool that writes single
bytes should repair `0xA3` afterwards.

## Settings

### Lighting

Two zones light independently: the palm-rest logo takes its colour from the user palette
at `0x39`, the strip under the wheel from the per-gear table at `0x57`.

Effect goes to `0xA5` as `effect + 0x81`; clearing bit 7 turns the lighting off.
Effect 0 is solid and 1 is the rainbow cycle — both confirmed on the device. Slots 2–7 are
accepted but their appearance was not checked.

LED colours do not match screen colours. The device's green and blue are much brighter
than its red, so `#30D158` arrives looking mint. Fully saturated channel mixes land far
closer to their name.

### DPI

Steps are 4-bit indices into a CPI table, not CPI values. The factory config uses steps
3, 6, 8, 9, 10 and 11, and 2E publishes six stages for this SKU —
800/1600/2400/3200/4800/6400 — which fixes those six. The remaining ten entries in the
app's table follow the same shape but are **inferred, not verified**, and the UI marks
them.

Writing a step is not enough on its own: the firmware re-reads the value only when the
active gear changes. `Device_Set_CPI_Value` therefore ends by writing `0xA6` with a
neighbouring gear and then the real one. Without that bump the new DPI appears only after
the next press of the DPI button.

Gear count is `0x2B + 1`, capped at 8; this mouse ships with 6, so only `0x2C`–`0x2E` hold
live data and `0x2F` must be left alone.

### Polling rate

Two bits in `0x04` (4 and 5) and one in `0x08` (bit 3), from `FUN_10007a50`:

| Rate | `0x04` bit 4 | `0x04` bit 5 | `0x08` bit 3 |
|---|---|---|---|
| 125 Hz | 0 | 0 | 0 |
| 250 Hz | 1 | 0 | 1 |
| 500 Hz | 0 | 1 | 1 |
| 1000 Hz | 1 | 1 | 1 |

Both bytes carry unrelated settings in their other bits, so they must be read-modify-
written. A live mouse read `0x04 = 0xBF`, `0x08 = 0xAF` — not the `0xAF` / `0x10` an
earlier guess assumed. The driver follows the change with the reload command and waits
half a second.

### Buttons

Twelve 4-byte slots per profile. The first byte is an action type and the rest are its
parameters:

| Type | Meaning |
|---|---|
| `01` | mouse button; parameter is the HID button mask (`01` left, `02` right, `04` middle, `08` back, `10` forward) |
| `09` | DPI action |
| `00` with zero parameters | disabled |
| `05`, `06` | seen in the factory config; not traced |

Which physical button each slot drives was never established, and neither were the
remaining action codes, so this app reads the table and does not write it. A wrong value
here can leave a button dead.

## The one real hazard: an abandoned block read

A block read is a stream. The header tells the firmware how many 7-byte chunks to hand
over, and it stays mid-stream until all of them have been collected. **Collecting only
part of a stream wedges the config channel.**

This was isolated by experiment rather than guessed at:

| Test | Result |
|---|---|
| 25 consecutive 352-byte block reads, one open handle | 25/25 fine |
| 25 of the same, reopening the device each time | 25/25 fine |
| 120 back-to-back single-byte writes | 120/120 fine |
| 10 colour-change cycles, 16 writes plus a read each | 10/10 fine |
| Take 3 chunks of 51, then do anything else | **wedged immediately** |

Once wedged, the channel answers `kIOReturnTimeout` to everything — reads *and* writes —
and no software recovery exists. The reload command cannot be delivered, because
delivering it is itself a write. Draining the stream does not help. Closing and reopening
the device does not help. Only unplugging the mouse does; the pointer keeps working the
whole time.

For anyone writing a tool against this chip: never interrupt the chunk loop — no
cancellation, no per-chunk retry — serialise all access so only one stream is ever in
flight, and do not let a second process touch the device at the same time. Each failed
transfer blocks for about five seconds, so once a chunk times out, give up rather than
looping.

## Persistence

Colours written this way survive a full unplug, so they reach non-volatile storage rather
than RAM. A replug is **not** an undo path — take a copy of the config image first if you
want one.
