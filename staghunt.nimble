version     = "0.1.0"
author      = "malcolm@stem.ai"
description = "Stag Hunt cogame: cooperative BitWorld hunting where rabbits go down alone but stags, moose, and elephants require coordinated multi-player encirclement."
license     = "MIT"

srcDir = "src"
bin = @["staghunt"]

switch("threads", "on")
switch("mm", "orc")

requires "nim >= 2.2.4"
requires "bitworld >= 0.1.0"
requires "mummy >= 0.4.7"
requires "pixie"
requires "supersnappy >= 2.1.3"
requires "whisky >= 0.1.3"
