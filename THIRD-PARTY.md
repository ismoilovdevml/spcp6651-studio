# Third-party components

No third-party code is vendored or compiled into this app.

## Protocol reference — reversed, not copied

The wire format was recovered from the vendor's own Windows driver, `SunplusIT_6651.dll`,
shipped inside `2E-MG330-V3.0.exe` from 2egaming.com. It was decompiled with
[Ghidra](https://ghidra-sre.org/) to learn the report layout, the config addresses and the
checksum rule; none of its code is present here. `MG330Protocol.swift` and
`MouseDevice.swift` were written in Swift from those facts and then re-verified against a
live mouse — every checksum the device reports reproduces from the formula in the source.

The published DPI stages used to label the six factory steps come from the retail listing
for this SKU (2E-MG330UB): 800/1600/2400/3200/4800/6400.

The window's visual design is shared with [N75 Studio](https://github.com/ismoilovdevml/n75-studio),
the author's app for the VGN N75 keyboard.

2E, MG330 and Sunplus are trademarks of their respective owners. This project is not
affiliated with or endorsed by any of them.
