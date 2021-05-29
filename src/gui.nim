import terminal, options

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

proc printStatus*(next: (string, ForegroundColor); held: Option[(string, ForegroundColor)]; score: string; color: bool = true) =
  eraseLine()
  stdout.write("Next: ")
  if color: setForegroundColor(next[1], bright = true)
  stdout.write(next[0])
  setForegroundColor(fgDefault)
  if held.isSome():
    stdout.write(", HoldBox: ")
    let h = held.get()
    if color: setForegroundColor(h[1], bright = true)
    stdout.write(h[0])
    setForegroundColor(fgDefault)
  stdout.write(" |")
  stdout.write(score & "\n")
  flushFile(stdout)

proc refresh*(ui: UI, color: bool = true) =
  cursorUp(Lines)
  setCursorXPos(0)
  for r in ui.tb:
    stdout.write('|')
    for c in r:
      if color: setForegroundColor(c.c, bright = true)
      stdout.write($ui.cellchars[c.k])
    setForegroundColor(fgDefault)
    stdout.write("|\n\r")
  for i in 0..<FieldSize.w+2:
    stdout.write('_')
  stdout.write("\n")
  flushFile(stdout)

proc displayMsg*(msg: string) =
  # displays a message overwriting the status line
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
