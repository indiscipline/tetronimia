from std/strformat import `&`
from std/strutils import strip

# Package

version       = "0.2.2"
author        = "Kirill I"
description   = "Nim implementation of tetris"
license       = "GPL-3.0-or-later"
srcDir        = "src"
bin           = @["tetronimia"]


# Dependencies
requires "nim >= 1.4.6", "threading >= 0.1.0", "cligen >= 1.5.4", "zero_functional >= 1.2.1"

task debug, "Build debug":
  let git = staticExec("git describe --tags HEAD").strip()
  let binName = &"{bin[0]}-{git}-{hostCPU}-{hostOS}" & (when defined(windows): ".exe" else: "")
  exec(&"nim c --define:debug --out:{binName} src/{bin[0]}.nim")
  exec(&"strip {binName}")

task release, "Build release":
  let binName = &"{bin[0]}-v{version}-{hostCPU}-{hostOS}" & (when defined(windows): ".exe" else: "")
  exec(&"nim c --define:danger --out:{binName} src/{bin[0]}.nim")
  exec(&"strip {binName}")
