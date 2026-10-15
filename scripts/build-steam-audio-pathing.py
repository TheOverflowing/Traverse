#!/usr/bin/env python3
"""Build an opt-in x64 Steam Audio proxy beside a copy of the original DLL.

Usage: build-steam-audio-pathing.py /path/to/original/phonon.dll /output/directory
The game is not modified. While it is closed, install phonon.dll in the original
plugin directory and phonon_traverse_original.dll beside the game's executable.
Keep the output original DLL as the restore copy.
"""
import pathlib
import re
import shutil
import subprocess
import sys

source = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2]).resolve()
root = pathlib.Path(__file__).resolve().parent.parent
metadata = subprocess.check_output(["x86_64-w64-mingw32-objdump", "-p", str(source)], text=True)
if "pei-x86-64" not in metadata:
    raise SystemExit("Only Windows x64 Steam Audio is supported.")
names = re.findall(r"^\s*\[\s*\d+\] \+base\[\s*(\d+)\]\s+[0-9a-f]+\s+(\S+)\s*$", metadata, re.M)
if not {"iplPathEffectApply", "iplPathEffectGetTail"} <= {name for _, name in names}:
    raise SystemExit("Steam Audio path-effect and tail APIs are required (tested with 4.6.0).")
output.mkdir(parents=True, exist_ok=True)
definition = output / "phonon.def"
definition.write_text("LIBRARY phonon\nEXPORTS\n" + "".join(
    f'"{name}"=' + ("traverse_path_effect_apply" if name == "iplPathEffectApply"
                     else f'"phonon_traverse_original.{name}"') + f" @{ordinal}\n"
    for ordinal, name in names))
subprocess.run(["x86_64-w64-mingw32-gcc", "-O2", "-Wall", "-Wextra", "-Werror",
                "-shared", "-static-libgcc", "-Wl,--no-insert-timestamp",
                str(root / "native/steam-audio-pathing.c"), str(definition),
                "-o", str(output / "phonon.dll")], check=True)
shutil.copy2(source, output / "phonon_traverse_original.dll")
print(f"Built {output / 'phonon.dll'} with {len(names)} original exports.")
