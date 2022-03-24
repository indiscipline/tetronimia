# Package

version       = "0.2.0"
author        = "Kirill I"
description   = "Nim implementation of tetris"
license       = "GPL-3.0-or-later"
srcDir        = "src"
bin           = @["tetronimia"]


# Dependencies

requires "nim >= 1.4.6", "threading >= 0.1.0", "cligen >= 1.5.4", "zero_functional >= 1.2.1"
