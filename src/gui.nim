import terminal, unicode

type
  Cell* = enum
    cEmpty, cPile, cTet, cGhost

const
  PIXELS* = ["░", "▉"] #▉░▓▮▀▁ ▂ ▃ ▄ ▅ ▆ ▇ █ ▉ ▊ ▋ ▌ ▍ ▎ ▏ ▐ ░ ▒ ▓ ▔ ▕ ▖ ▗ ▘ ▙ ▚ ▛ ▜ ▝ ▞ ▟ 
  FieldSize* = (w: 10, h: 21)
  StartPos* = (x: FieldSize.w div 2 - 2, y: -1)
  FieldOffset = (x: 1, y: 0)
  Lines = FieldSize.h + FieldOffset.y + 2
  CellChars: array[Cell, char] = [' ', '*', '#', '.']
  #CellKind = enum
  #  cPile, cTet, cGhost
  #Cell* = object
  #  case empty: bool
  #    of false: kind: CellKind
  #    of true:

type
  TerminalBuffer = array[FieldSize.h + 1, array[FieldSize.w + 2, char]]
  UI* = object
    tb: TerminalBuffer
    status*: string
  Field* = array[FieldSize.h, array[FieldSize.w, Cell]]

proc drawStack(tb: var TerminalBuffer) =
  for l in FieldOffset.y .. (FieldOffset.y + FieldSize.h - 1):
    tb[l][FieldOffset.x - 1] = '|'
    tb[l][FieldOffset.x + FieldSize.w] = '|'
  for c in FieldOffset.x - 1 .. FieldOffset.x + FieldSize.w:
    tb[FieldOffset.y + FieldSize.h][c] = '_'

proc print(tb: TerminalBuffer) =
  for l in tb:
    setCursorXPos(0)
    let s = @l
    echo cast[string](s) # TODO: works as long as string == seq[char]

proc refresh*(ui: UI) =
  cursorUp(Lines)
  print(ui.tb)
  eraseLine()
  echo(ui.status)

proc update*(ui: var UI; field: sink Field; ch: char = '#') =
  for (y, row) in field.pairs():
    for (x, c) in row.pairs():
      ui.tb[y + FieldOffset.y][x + FieldOffset.x] =
        CellChars[c] #case f c != cEmpty: '#' else: ' '

proc guiInit*(field: sink Field): UI =
  hideCursor()
  result.tb.drawStack()
  result.update(field)
  for l in 0..<Lines: echo "" # refresh moves cursor up, preparing blank space here
  result.refresh()

proc deinit*() =
  showCursor()
