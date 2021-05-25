import 
  std/[random, lists, os, threadpool, channels, locks, terminal],
  zero_functional, cligen, gui
from std/math import `^`

type
  Coord = tuple[x, y: int]
  TCells = array[4, Coord]

  TetronimoKind = enum
    TO = "O", TI = "I", TS = "S", TZ = "Z", TL = "L", TJ = "J", TT = "T"

  Tetronimo = object
    kind: TetronimoKind
    rotation: int
    pos: Coord
  
  ## A pile of fallen blocks, bottom to top
  Pile = object
    rows: SinglyLinkedList[array[FieldSize.w, Cell]]
    height: int

  Stats = tuple[cleared, score, level: int]

  State = object
    ui: UI
    tetros: iterator(): Tetronimo
    pile: Pile
    curT, nextT, ghostT: Tetronimo
    paused: bool
    stats: Stats
  
  MessageKind = enum
    mkCommand, mkMovement
  Movement = enum
    mDown, mLeft, mRight, mRotate, mDrop
  Command = enum
    cPause
  Message = object
    case kind: MessageKind
      of mkMovement: move: Movement
      of mkCommand: command: Command
  
  SpeedCurveKind = enum
    scNimia = "n", scWorld = "w"
  
  Options = object
    lock: Lock
    descendPeriod {.guard: lock.}: int
    speedCurve: SpeedCurveKind
    hardDrop: bool
    ghost: bool 

var
  bus = newChannel[Message]()
  options: Options

func apply[T, N, U](a: array[N, T]; p: proc (x:T):U {.noSideEffect.} ): array[N, U] =
  for (i, x) in a.pairs(): result[i] = p(x)

func tOffsets(n: uint16): TCells =
  ## Will fail with oob on more than 4 ones in `n`.
  var cell = 3
  for i in 0..15:
    if (n and (1'u16 shl i)) != 0:
      result[cell] = (x: 3 - (i mod 4), y: 3 - (i div 4))
      cell.dec()

const
  LT = (
    rTO: [0b0000011001100000'u16].apply(tOffsets), #TO
    rTI: [0b0000111100000000'u16, 0b0010001000100010'u16].apply(tOffsets), #TI
    rTS: [0b0000001101100000'u16, 0b0010001100010000'u16].apply(tOffsets), #TS
    rTZ: [0b0000011000110000'u16, 0b0001001100100000'u16].apply(tOffsets), #TZ
    rTL: [0b0000011101000000'u16, 0b0010001000110000'u16, 0b0001011100000000'u16, 0b0110001000100000'u16].apply(tOffsets), #TL
    rTJ: [0b0000011100010000'u16, 0b0011001000100000'u16, 0b0100011100000000'u16, 0b0010001001100000'u16].apply(tOffsets), #TJ
    rTT: [0b0000011100100000'u16, 0b0010001100100000'u16, 0b0010011100000000'u16, 0b0010011000100000'u16].apply(tOffsets)) #TT

  Rules = (LineClear: [0, 1, 3, 5, 8])
  HelpStr = {
    "help-syntax": "CLIGEN-NOHELP",
    "speedcurve": "Select how the speed changes on level advancement\n" &
                  "n - Default 'Nimia' mode\n" &
                  "w - Famous 'World' mode",
    "nohdrop": "Disable the hard drop",
    "noghost": "Disable the ghost Tetronimo"
  }
  ShortStr = {
    "speedcurve": 's',
    "nohDrop": 'D',
    "noGhost": 'G'
  }

###############################################################################
func tCells(tk: TetronimoKind; rotation: int): TCells =
  # Why can't `LT[tk.ord][rotation]` just do it for me?
  case tk:
    of TO: LT.rTO[rotation]
    of TI: LT.rTI[rotation]
    of TS: LT.rTS[rotation]
    of TZ: LT.rTZ[rotation]
    of TL: LT.rTL[rotation]
    of TJ: LT.rTJ[rotation]
    of TT: LT.rTT[rotation]

func tCells(t: Tetronimo): TCells = tCells(t.kind, t.rotation)

func rotate(t: Tetronimo): int =
  case t.kind:
    of TO: t.rotation
    of TI..TZ: (t.rotation + 1) mod 2
    of TL..TT: (t.rotation + 1) mod 4

iterator nextTetronimo(): Tetronimo {.closure.} =
  ## Yields tetronimos in their default rotation,
  ## according to the official "Random Generator" algo:
  ##  1. Fill the "bag" with 7 pieces, one of each kind
  ##  2. Draw them one-by-one
  ##  3. Repeat
  var tetronimoKinds = [TO, TI, TS, TZ, TL, TJ, TT]
  while true:
    shuffle(tetronimoKinds)
    for n in tetronimoKinds:
      yield Tetronimo(kind: n, rotation: 0, pos: StartPos)

proc next[T](it: var iterator(): T): T = (for x in it(): return x)

func `+`(pos: Coord, offsets: TCells): TCells {.inline.} =
  for i in 0..3:
    result[i] = (x: offsets[i].x + pos.x, y: offsets[i].y + pos.y)

###############################################################################
func getUnsafe[T](l: SinglyLinkedList[T]; n: Natural): SinglyLinkedNode[T] =
  ## Gets Nth row of the list unsafely, `n` must be valid!
  result = l.head
  var row = 0
  while row < n:
    result = result.next
    row.inc()

func get(p: Pile; pos: Coord): bool =
  ## Check if the cell is in the Pile, coordinates relative to the field
  ## Relies on `p.height` for iteration: must be valid!
  let y = FieldSize.h - (pos.y + 1) # invert vertical coord
  y < p.height and (p.rows.getUnsafe(y).value[pos.x] != cEmpty) # short-circuits, do not reorder!

proc setUnsafe(p: Pile; pileCell: Coord) {.inline.} =
  ## Occupies a cell in the pile, coordinates relative to the pile
  ## Unsafely iterates the pile. `pileCell.y` must be valid!
  p.rows.getUnsafe(pileCell.y).value[pileCell.x] = cPile

proc add(p: var Pile; cells: TCells) =
  for i in countDown(3, 0):
    let y = FieldSize.h - (cells[i].y + 1)
    while y > p.height - 1:
      var newRow: array[FieldSize.w, Cell]
      p.rows.append(newRow)
      p.height.inc()
    p.setUnsafe((x: cells[i].x, y: y))

proc clearFull(p: var Pile): int =
  var h = p.rows.head
  if h != nil:
    while h.next != nil: # clear tail
      if h.next.value --> all(it != cEmpty):
        h.next = h.next.next
        p.height.dec()
        result.inc()
      else:
        h = h.next
    h = p.rows.head # clear head
    if h.value --> all(it != cEmpty):
      p.rows.head = h.next # also works when `h.next == nil`
      p.height.dec()
      result.inc()

###############################################################################
func isValidMove(t: Tetronimo; newPos: Coord; newRotation: int; p: Pile): bool =
  let
    occupies = newPos + tCells(t.kind, newRotation)
    inside = occupies --> all((it.x in 0..<FieldSize.w) and (it.y in 0..<FieldSize.h))
  result = inside and not (occupies --> exists(p.get(it)))

func isValidMove(t: Tetronimo; p: Pile): bool = isValidMove(t, t.pos, t.rotation, p)

proc descend() {.thread.} =
  var dp: int
  while true:
    withLock(options.lock):
      dp = options.descendPeriod
    sleep(dp)
    bus.send(Message(kind: mkMovement, move: mDown))

proc safelyQuit() {.noconv.} =
  deinit()
  quit(0)

proc waitForInput() {.thread.} =
  var
    c: char
    msg: Message
  while true:
    c = getch()
    case c:
      of 'h', 'H': msg = Message(kind: mkMovement, move: mLeft)
      of 'l', 'L': msg = Message(kind: mkMovement, move: mRight)
      of 'j', 'J', char(13): msg = Message(kind: mkMovement, move: mDown)
      of 'k', 'K', char(9): msg = Message(kind: mkMovement, move: mRotate)
      of 'd', 'D', ' ': msg = 
        Message(kind: mkMovement, move:(if options.hardDrop: mDrop else: mDown))
      of 'p', 'P', char(27): msg = Message(kind: mkCommand, command: cPause)
      of 'q', 'Q', char(3): safelyQuit()
      of char(26): 
        when defined(Windows): continue else: stdout.write(char(26)) 
      else: continue
    bus.send(msg)

func calcMove(t: Tetronimo; move: Movement): Tetronimo {.noinit.} =
  result.kind = t.kind
  result.rotation = t.rotation 
  case move:
    of mDown, mDrop: result.pos = (t.pos.x, t.pos.y + 1)
    of mLeft: result.pos = (t.pos.x - 1, t.pos.y)
    of mRight: result.pos = (t.pos.x + 1, t.pos.y)
    of mRotate: result.rotation = rotate(t); result.pos = t.pos

func buildField(p: Pile): Field =
  var y = FieldSize.h - 1
  for row in p.rows:
    result[y] = row
    y.dec()

func addTetronimo(f: sink Field; t: Tetronimo; ghost: bool = false): Field {.noinit inline.}=
  for c in (t.pos + tCells(t)):
    if f[c.y][c.x] != cPile:
      f[c.y][c.x] = if ghost: cGhost else: cTet
  f

func formatScore(s: Stats): string {.noinit, inline.} =
  " Score: " & $s.score & ", Cleared: " & $s.cleared & ", Level: " & $s.level

proc updateSpeed(o: var Options; level:int) =
  withLock o.lock:
    o.descendPeriod = case o.speedCurve:
      of scNimia: toInt(1000.0 * (0.88 ^ level))
      of scWorld: toInt(1000.0 * ((0.8 - 0.007 * ((toFloat(level) - 1.0))) ^ (level - 1)))

proc updateStats(s: var Stats; cleared: int) {.inline.} =
  s.cleared.inc(cleared)
  s.score.inc(Rules.LineClear[cleared])
  let newLevel = 1 + s.cleared div 10
  if newLevel > s.level:
    s.level = newLevel
    updateSpeed(options, newLevel)

proc updateGhost(g: var Tetronimo, cur: Tetronimo, p: Pile) =
  g = cur
  while true:
    let tmp = calcmove(g, mDown)
    if isValidMove(tmp, p):
      g = tmp
    else:
      break

proc lockAndAdvance(s: var State): bool =
  ## Locks the current Tetronimo at its position if possible.
  ## Returns false on fail == Game Over
  s.pile.add(s.curT.pos + tCells(s.curT))
  if isValidMove(s.nextT, s.pile):
    s.curT = s.nextT
    s.nextT = s.tetros.next()
    true
  else:
    false

proc main(state: sink State) =
  var
    updateDue = false
    msg: Message
  # Spawn threads
  spawn descend()
  spawn waitForInput()

  block mainLoop:
    while true:
      # Receive and react to messages
      while bus.tryRecv(msg):
        if msg.kind == mkCommand:
          if msg.command == cPause:
            state.paused = not state.paused
            if state.paused:
              state.ui.status = "Paused. Press 'P' or 'Esc' to contiue..."
              state.ui.refresh
          updateDue = not state.paused
        elif not state.paused: # move only when not paused
          let updatedT = calcMove(state.curT, msg.move)
          let nextOk = isValidMove(updatedT, state.pile)
          state.ghostT.updateGhost(if nextOk: updatedT else: state.curT, state.pile)
        
          updateDue = true # any valid unpaused move leads to redraw
          case msg.move:
            of mLeft, mRight, mRotate:
              if nextOk: state.curT = updatedT
              else: updateDue = false
            of mDown:
              if nextOk: state.curT = updatedT
              elif not lockAndAdvance(state): # Can't descend
                break mainLoop  # Game Over!
            of mDrop:
              state.curT = state.ghostT
              if not lockAndAdvance(state):
                break mainLoop
      
      if updateDue:
        let cleared = state.pile.clearFull()
        if cleared > 0:
          state.stats.updateStats(cleared)
          state.ghostT.updateGhost(state.curT, state.pile) # redraw ghost to avoid lag
        var field = buildField(state.pile)
        if options.ghost:
          field = field.addTetronimo(state.ghostT, ghost = true)
        field = field.addTetronimo(state.curT) 
        state.ui.update(field)
        state.ui.status = "Next: " & $state.nextT.kind & formatScore(state.stats) 
        state.ui.refresh()
        updateDue = false
     
      sleep(33)
  
  state.ui.status = "Game Over! Final" & formatScore(state.stats)
  state.ui.refresh()

proc init(): State =
  result.tetros = nextTetronimo
  result.curT = result.tetros.next()
  result.nextT = result.tetros.next()
  let field = buildField(result.pile).addTetronimo(result.curT)
  result.ui = guiInit(field)
  result.stats.updateStats(0)

proc tetronimia(speedcurve: SpeedCurveKind = scNimia, nohdrop: bool = false, noghost: bool = false) =
  ## Tetronimia: the only winning move is not to play
  ##
  ## Default keys: 
  ##  Left: H, Soft drop: J|Enter, Rotate: K|Tab, Right: L,
  ##  Hard drop: D|Space, Pause: P|Esc, Exit: Q|Ctrl+C
  options.speedCurve = speedcurve
  options.hardDrop = not nohdrop
  options.ghost = not noghost
  randomize()
  setControlCHook(safelyQuit)
  main(init())
  safelyQuit()

when isMainModule:
  clCfg.hTabCols = @[ clOptKeys, clDflVal, clDescrip] # hide types column
#  dispatch(tetronimia, help = HelpStr, short = ShortStr)
  dispatch(tetronimia, help = {
    "help-syntax": "CLIGEN-NOHELP",
    "speedcurve": "Select how the speed changes on level advancement\n" &
                  "n - Default 'Nimia' mode\n" &
                  "w - Famous 'World' mode",
    "nohdrop": "Disable the hard drop",
    "noghost": "Disable the ghost Tetronimo"
  }, short = {
    "speedcurve": 's',
    "nohdrop": 'D',
    "noghost": 'G'
  }
  )
