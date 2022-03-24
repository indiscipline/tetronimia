import
  std/[random, times, lists, os, threadpool, locks, terminal, base64,
  options, tables, strformat],
  threading/channels, zero_functional, cligen, gui, shufflearray
from std/math import `^`

## Autodefined by Nimble. If built using pure nim, use git tag.
const NimblePkgVersion {.strdefine.} = staticExec "git describe --tags HEAD"

type
  Coord = tuple[x, y: int]
  TCells = array[4, Coord]

  TetronimoKind = enum
    TO = "O", TI = "I", TS = "S", TZ = "Z", TL = "L", TJ = "J", TT = "T"

  RotationDir = enum
    CW = "cw", CCW = "ccw"

  Tetronimo = object
    kind: TetronimoKind
    rotation: Natural
    pos: Coord

  ## A pile of fallen blocks, bottom to top
  Pile = ShuffleArray[FieldSize.h, array[FieldSize.w, Cell]]

  Stats = tuple[cleared, score, level: int]

  SpeedCurveKind = enum
    scNimia = "n", scWorld = "w"

  Options = object
    lock: Lock
    descendPeriod {.guard: lock.}: int
    speedCurve: SpeedCurveKind
    rotation: RotationDir
    hardDrop: bool
    ghost: bool
    holdBox: bool
    delayOnClear: bool
    scoreDrops: bool
    color: bool
    seed: int64

  State = object
    ui: UI
    tetros: iterator(): Tetronimo
    pile: Pile
    curT, nextT, ghostT, heldT: Tetronimo
    opts: Options
    paused: bool
    usedHold: bool
    stats: Stats
    gameOver: bool

  MessageKind = enum
    mkCommand, mkMovement
  Movement = enum
    mTick, mDown, mLeft, mRight, mRotateCw, mRotateCcw, mDrop
  Command = enum
    cPause, cClearDelay, cHold, cQuit
  Message = object
    case kind: MessageKind
      of mkMovement: move: Movement
      of mkCommand: command: Command

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

  Rules = (
    LCScoring: [0, 10, 30, 50, 80],
    Colors: array[TetronimoKind, ForegroundColor]([fgYellow, fgCyan, fgGreen, fgRed, fgMagenta, fgBlue, fgWhite]),
    Salt: 0b01001100011100001111000001111110000001111100001111000111001101'i64
  )

  HelpS = {
    "help-syntax": "CLIGEN-NOHELP",
    "speedcurve": "Select how the speed changes on level advancement:\n" &
                  " n - Default 'Nimia' mode. Cruising to the inevitable.\n" &
                  " w - Famous 'World' mode. Impetuous crescendo.",
    "rotation": "Select the rotation direction:\n ccw - counterclockwise (default)\n cw - clockwise.",
    "nohdrop": "Disable the hard drop.",
    "noghost": "Disable the ghost Tetronimo.",
    "holdbox": "Enable the Hold Box.",
    "charset": "Override the characters for the Pile, the Tetronimos and the Ghost.",
    "nolcdelay": "Disable delay on Line Clear.",
    "nodropreward": "Disable rewarding soft and hard drops.",
    "nocolor": "Disable the coloring.",
    "gameseed": "Initialize random generator (use for competitive replay).",
    "help": "Print this help text.",
    "version": "Print version and exit.",
  }.toTable()
  ShortS = {
    "speedcurve": 's',
    "rotation": 'r',
    "nohdrop": 'D',
    "noghost": 'G',
    "holdbox": 'b',
    "charset": 'c',
    "nolcdelay": 'L',
    "nodropreward": 'R',
    "nocolor": 'M',
    "gameseed": 'g',
    "version": 'v',
  }.toTable()

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

func rotate(t: Tetronimo, rd: RotationDir): Natural =
  case t.kind:
    of TO: t.rotation
    of TI..TZ: (t.rotation + 1) mod 2
    of TL..TT: (t.rotation + (if rd == CCW: 1 else: 3)) mod 4

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
func get(p: Pile; pos: Coord): bool =
  ## Check if the cell is in the Pile, coordinates relative to the field
  let y = FieldSize.h - (pos.y + 1) # invert vertical coord
  y < p.len() and p[y][pos.x].k != cEmpty # short-circuits, do not reorder!

proc add(p: var Pile; cells: TCells, kind: TetronimoKind) =
  for i in countDown(3, 0):
    let y = FieldSize.h - (cells[i].y + 1)
    while p.len() - 1 < y:
      p.append()
    p[y][cells[i].x] = Cell(k: cPile, c: Rules.Colors[kind])

template clearFull(p: var Pile): int =
  p.retainIf( proc(x: Pile.T): bool = not (x --> all(it.k != cEmpty)) )
###############################################################################
func isValidMove(t: Tetronimo; newPos: Coord; newRotation: int; p: Pile): bool =
  let
    occupies = newPos + tCells(t.kind, newRotation)
    inside = occupies --> all((it.x in 0..<FieldSize.w) and (it.y in 0..<FieldSize.h))
  result = inside and not (occupies --> exists(p.get(it)))

func isValidMove(t: Tetronimo; p: Pile): bool = isValidMove(t, t.pos, t.rotation, p)

proc safelyQuit() {.noconv.} =
  resetAttributes()
  deinit()
  quit(0)

func calcMove(t: Tetronimo; move: Movement): Tetronimo {.noinit.} =
  result.kind = t.kind
  result.rotation = t.rotation
  case move:
    of mDown, mDrop, mTick: result.pos = (t.pos.x, t.pos.y + 1)
    of mLeft: result.pos = (t.pos.x - 1, t.pos.y)
    of mRight: result.pos = (t.pos.x + 1, t.pos.y)
    of mRotateCcw: result.rotation = rotate(t, CCW); result.pos = t.pos
    of mRotateCw: result.rotation = rotate(t, CW); result.pos = t.pos

proc buildField(p: Pile): Field =
  ## Doesn't check for p.height
  var y = FieldSize.h - 1
  for row in p:
    result[y] = row
    y.dec()

func addTetronimo(f: sink Field; t: Tetronimo; ghost: bool = false): Field {.noinit inline.}=
  for c in (t.pos + tCells(t)):
    if f[c.y][c.x].k != cPile:
      f[c.y][c.x] = Cell(k: (if ghost: cGhost else: cTet), c: Rules.Colors[t.kind])
  f

func `$`(s: Stats): string {.noinit, inline.} =
  &" Score: {s.score}, Cleared: {s.cleared}, Level: {s.level}"

template refreshStatus(next, held: Tetronimo; stats: Stats; opts: Options) =
  printStatus(
    ($next.kind, Rules.Colors[next.kind]), (
    if opts.holdBox:
      some(($held.kind, Rules.Colors[held.kind]))
    else:
      none((string, ForegroundColor))
    ), $stats, opts.color)

proc updateStats(s: var Stats; opts: var Options; cleared: Natural) {.inline.} =
  s.cleared.inc(cleared)
  s.score.inc(Rules.LCScoring[cleared] * s.level)
  let newLevel = 1 + s.cleared div 10
  if newLevel > s.level:
    s.level = newLevel
    withLock opts.lock:
      opts.descendPeriod = case opts.speedCurve:
        of scNimia: toInt(1000.0 * (0.88 ^ s.level))
        of scWorld: toInt(1000.0 * ((0.8 - 0.007 * ((toFloat(s.level) - 1.0))) ^ (s.level - 1)))

template scoreHardDrop(s: var Stats; fromY: int) =
  ## Doesn't matter how long's the drop, but how soon it happens
  s.score.inc((FieldSize.h - fromY - 1) * s.level)

template scoreSoftDrop(s: var Stats) =
  s.score.inc(s.level)

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
  s.pile.add(s.curT.pos + tCells(s.curT), s.curT.kind)
  if isValidMove(s.nextT, s.pile):
    s.curT = s.nextT
    s.nextT = s.tetros.next()
    s.usedHold = false
    true
  else:
    false

proc ticker(bus: ptr Chan[Message]; opts: ptr Options) {.thread.} =
  var dp: int
  while true:
    withLock(opts[].lock):
      dp = opts[].descendPeriod
    sleep(dp)
    bus[].send(Message(kind: mkMovement, move: mTick))

proc waitForInput(bus: ptr Chan[Message]; opts: ptr Options; gameOver: ptr bool) {.thread.} =
  var
    c: char
    msg: Message
  while true:
    c = getch()
    if not gameOver[]:
      case c:
        of 'h', 'H': msg = Message(kind: mkMovement, move: mLeft)
        of 'l', 'L': msg = Message(kind: mkMovement, move: mRight)
        of 'j', 'J', char(13): msg = Message(kind: mkMovement, move: mDown)
        of 'k', 'K', char(9): msg =
          Message(kind: mkMovement, move: if opts[].rotation == CCW: mRotateCcw else: mRotateCw)
        of 'd', 'D', ' ': msg =
          Message(kind: mkMovement, move: if opts[].hardDrop: mDrop else: mDown)
        of 'f', 'F': msg = Message(kind: mkCommand, command: cHold)
        of 'p', 'P', char(27): msg = Message(kind: mkCommand, command: cPause)
        of 'q', 'Q', char(3): msg = Message(kind: mkCommand, command: cQuit)
        of char(26):
          when defined(Windows): continue else: stdout.write(char(26))
        else: continue
      bus[].send(msg)
    else:
      bus[].send(Message(kind: mkCommand, command: cQuit))
      break

proc clearDelay(bus: ptr Chan[Message]; level: Natural) {.thread.} =
  bus[].send(Message(kind: mkCommand, command: cClearDelay))
  sleep(toInt( 750.0 * (0.92 ^ level) ))
  bus[].send(Message(kind: mkCommand, command: cClearDelay))

################################################################################
proc genSeed(): int64 =
  let now = times.getTime()
  (convert(Seconds, Nanoseconds, now.toUnix) + now.nanosecond)

proc serialize(i: int64): string =
  encode(cast[array[8, byte]](i xor Rules.Salt))

func deserialize(s: string): int64 =
  var a: array[8, char]
  var i = 0
  let d = decode(s)
  while i < 8 and i < d.len:
    a[i] = d[i]
    i.inc
  cast[int64](a) xor Rules.Salt

proc `$`(opts: Options): string {.noinit, inline.} =
  func short(t: tuple[o: bool; key: string]): string =
    if t.o: $ShortS[t.key] else: ""
  let optStr: string = [
      (not opts.hardDrop, "nohdrop"),
      (not opts.ghost, "noghost"),
      (opts.holdBox, "holdbox"),
      (not opts.delayOnClear, "nolcdelay"),
      (not opts.scoreDrops, "nodropreward")
    ] --> map(short).fold(" -", a & it)
  &"Game settings: \"-s={opts.speedCurve} -r={opts.rotation}" &
  (if optStr != " -": optStr else: "") &
  &" --gameseed {serialize(opts.seed)}\""

################################################################################
proc main(state: sink State) =
  var
    updateDue = false
    msg: Message
    bus = newChan[Message]() # Create a shared channel

  # Spawn threads
  spawn ticker(addr bus, addr state.opts)
  spawn waitForInput(addr bus, addr state.opts, addr state.gameOver)

  block mainLoop:
    while true:
      while bus.tryRecv(msg): # Receive and react to messages
        if msg.kind == mkCommand:
          case msg.command:
            of cPause: # pause publicly
              state.paused = not state.paused
              if state.paused:
                displayMsg("Paused. Press 'P' or 'Esc' to continue...")
            of cClearDelay: # pause privately
              state.paused = not state.paused
            of cHold:
              if state.opts.holdBox and not state.usedHold:
                let updatedT =
                  Tetronimo(kind: state.heldT.kind, rotation: 0, pos: StartPos)
                if isValidMove(updatedT, state.pile):
                  state.heldT.kind = state.curT.kind
                  state.curT = updatedT
                  state.ghostT.updateGhost(state.curT, state.pile) # update ghost
                  state.usedHold = true
            of cQuit:
              break mainLoop
          updateDue = not state.paused
        elif not state.paused: # move only when not paused
          let updatedT = calcMove(state.curT, msg.move)
          let nextOk = isValidMove(updatedT, state.pile)
          state.ghostT.updateGhost(if nextOk: updatedT else: state.curT, state.pile)
          updateDue = true # any valid unpaused move leads to redraw
          case msg.move:
            of mLeft, mRight, mRotateCcw, mRotateCw:
              if nextOk: state.curT = updatedT
              else: updateDue = false
            of mDown, mTick:
              if nextOk:
                state.curT = updatedT
                if msg.move == mDown and state.opts.scoreDrops: state.stats.scoreSoftDrop()
              elif not lockAndAdvance(state): # Can't descend
                state.gameOver = true
                break mainLoop # Game Over!
            of mDrop:
              if state.opts.scoreDrops: state.stats.scoreHardDrop(state.curT.pos.y)
              state.curT = state.ghostT
              if not lockAndAdvance(state):
                state.gameOver = true
                break mainLoop # Game Over!

      if updateDue:
        let cleared = state.pile.clearFull()
        if cleared > 0:
          state.stats.updateStats(state.opts, cleared)
          state.ghostT.updateGhost(state.curT, state.pile) # replace ghost to avoid lag
          if state.opts.delayOnClear:
            spawn clearDelay(addr bus, state.stats.level)
        var field = buildField(state.pile)
        if state.opts.ghost:
          field = field.addTetronimo(state.ghostT, ghost = true)
        field = field.addTetronimo(state.curT)
        state.ui.update(field)
        state.ui.refresh(state.opts.color)
        refreshStatus(state.nextT, state.heldT, state.stats, state.opts)
        updateDue = false
      sleep(33)
  if state.gameOver:
    displayMsg(&"Game Over! Final{state.stats} \n\r{state.opts}")
    when defined(Windows):
    # This block is known to be necessary only for cmd.exe
    # but we won't discriminate between Windows users
      echo("\rPress any key to exit...")
      while true: # Ticker isn't stopped and channel buffer can be non-empty
        bus.recv(msg)
        if msg.kind == mkCommand and msg.command == cQuit:
          break
  safelyQuit()

proc initState(opts: sink Options, charset: sink string): State =
  var tetros = nextTetronimo
  let
    curT = tetros.next()
    nextT = tetros.next()
    stats = (var s: Stats; s.updateStats(opts, 0); s)
    pile = initShuffleArray[FieldSize.h, array[FieldSize.w, Cell]]()
    heldT = (var t: Tetronimo; t.kind = rand(TO..TT); t)
    ui = guiInit(buildField(pile).addTetronimo(curT), charset)
  refreshStatus(nextT, heldT, stats, opts)
  State(tetros: tetros, pile: pile, stats: stats, curT: curT, nextT: nextT,
        heldT: heldT, opts: opts, ui: ui)

proc tetronimia(speedcurve: SpeedCurveKind = scNimia; rotation: RotationDir = CW; nohdrop: bool = false, noghost: bool = false, holdbox: bool = false, nolcdelay: bool = false, nodropreward: bool = false, nocolor: bool = false; charset = "", gameseed = "") =
  ## Tetronimia: the only winning move is not to play
  ##
  ## Default controls:
  ##  Left: H, Soft drop: J|Enter, Rotate: K|Tab, Right: L,
  ##  Hard drop: D|Space, HoldBox: F
  ##  Pause: P|Esc, Exit: Q|Ctrl+C
  ##
  var opts: Options
  opts.speedCurve = speedcurve
  opts.rotation = rotation
  opts.hardDrop = not nohdrop
  opts.ghost = not noghost
  opts.holdBox = holdbox
  opts.delayOnClear = not nolcdelay
  opts.scoreDrops = not nodropreward
  opts.color = not nocolor
  opts.seed = if gameseed != "": deserialize(gameseed)
              else: genSeed()
  randomize(opts.seed)
  setControlCHook(safelyQuit)
  opts.lock.initLock() # necessary for Windows?
  main(initState(opts, charset))
  safelyQuit()

when isMainModule:
  clCfg.hTabCols = @[clOptKeys, clDescrip] # hide types and default value columns
  clCfg.version = NimblePkgVersion
  dispatch(tetronimia, help = HelpS, short = ShortS)
