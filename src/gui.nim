import std/[terminal, options]
from std/strutils import repeat

type
  CellKind* = enum
    cEmpty, cPile, cTet, cGhost

  Cell* = object
    k*: CellKind
    c*: ForegroundColor

const
  FieldSize* = (w: 10, h: 21)
  StartPos* = (x: FieldSize.w div 2 - 2, y: -1)
  TBs = (w: FieldSize.w + 2 + 2, h: (FieldSize.h + 1))
  Lines = TBs.h + 1 # TB + status line

type
  Field* = array[FieldSize.h, array[FieldSize.w, Cell]]
  UI* = object
    tb: Field
    cellChars: array[CellKind, char] #
    status*: string
    score: string

proc update*(ui: var UI; field: sink Field) =
  ui.tb = field

template writeColored(s: string, c: ForegroundColor, color: bool = true) =
  if color:
    stdout.styledWrite(if c.ord() == 0: fgDefault else: c, styleBright, s, resetStyle)
  else:
    stdout.write(s)

proc printStatus*(next: (string, ForegroundColor); held: Option[(string, ForegroundColor)]; score: string; color: bool = true) =
  eraseLine()
  stdout.write("Next: ")
  writeColored(next[0], next[1], color)
  if held.isSome():
    stdout.write(", HoldBox: ")
    let h = held.get()
    writeColored(h[0], h[1], color)
  stdout.write(" |" & score & "\n")
  flushFile(stdout)

proc refresh*(ui: UI, color: bool = true) =
  cursorUp(Lines)
  setCursorXPos(0)
  for r in ui.tb:
    stdout.write('|')
    for c in r:
      writeColored($ui.cellchars[c.k], c.c, color)
    stdout.write("|\n\r")
  echo("_".repeat(FieldSize.w+2))

proc displayMsg*(msg: string) =
  ## Displays a message overwriting the status line
  cursorUp()
  eraseLine()
  echo(msg)

proc parseCharset*(cs: string): array[4, char] =
  result = [' ', '*', '#', '.']
  if cs.len in 1..2: stderr.write("The charset is too short. Using the defaut one.")
  elif cs.len >= 3: result[1..3] = cs[0..2]

proc guiInit*(field: sink Field, charset: string): UI =
  hideCursor()
  result.cellChars = parseCharset(charset)
  result.update(field)
  for l in 0..<Lines: echo("") # refresh moves cursor up, preparing blank space here
  result.refresh()

proc deinit*() =
  setCursorXPos(0)
  showCursor()
