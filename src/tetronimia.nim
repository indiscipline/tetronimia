import
  std/[random, times, lists, os, terminal, base64, options, tables, strformat, exitprocs],
  threading/[channels, atomics],
  pkg/[zero_functional, cligen, cligen/argcvt],
  kbd, gui, shufflearray
from std/math import `^`
from std/strutils import strip
from illwill import getKey, Key, illwillInit, illwillDeinit

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
    speedCurve: SpeedCurveKind
    rotation: RotationDir
    hardDrop: bool
    ghost: bool
    holdBox: bool
    delayOnClear: bool
    scoreDrops: bool
    color: bool
    seed: int64
    kbdPreset: KbdPreset

  State = object
    ui: UI
    tetros: iterator(): Tetronimo
    pile: Pile
    curT, nextT, ghostT, heldT: Tetronimo
    opts: Options
    paused: bool
    usedHold: bool
    stats: Stats
    descendPeriod: Atomic[int]
    gameOver: Atomic[bool]

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

#  Type helpers  ##############################################################
template msg(k: MessageKind; m: Movement): Message = Message(kind: k, move: m)

template msg(k: MessageKind; c: Command): Message = Message(kind: k, command: c)

#  Static section  ############################################################
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
  ## Autodefined by Nimble. If built using pure nim, use git tag
  NimblePkgVersion {.strdefine.} = staticExec("git describe --tags HEAD").strip()

  UITick = 33

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

  DocS = &"""
Tetronimia {NimblePkgVersion}: the only winning move is not to play

Default controls (equal to --kbd=vim):
 Left: H, Soft drop: J|Enter, Rotate: K|Tab, Right: L,
 Hard drop: D|Space, HoldBox: F
 Pause: P|Esc, Exit: Q|Ctrl+C"""

  KbdS = fmt"""Keyboard controls. Takes a name of a built-in preset or a string with
the custom keybindings. CtrlC always exits, so "Exit" can be omitted.
Built-in presets and their expanded form:
 vim = {KbdPresetVim}
 emacs = {KbdPresetEmacs}
 wasd = {KbdPresetWASD}
 casual = {KbdPresetCasual}
Valid keys for user presets: printable characters, escape, enter, tab, space,
arrow keys, pgup, pgdown, home, end, insert, delete, backspace."""

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
    "kbd": KbdS,
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
    "kbd": 'k',
    "gameseed": 'g',
    "version": 'v',
  }.toTable()

#  [De]serializing options, seed generation  ##################################
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

#  Pile impl  #################################################################
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

func newDescendPeriod(level: int; sc: SpeedCurveKind): int {.inline.} =
  case sc:
    of scNimia: toInt(1000.0 * (0.88 ^ level))
    of scWorld: toInt(1000.0 * ((0.8 - 0.007 * ((toFloat(level) - 1.0))) ^ (level - 1)))

proc updateAndLvlUp(s: var Stats; newCleared: Natural): bool =
  s.cleared.inc(newCleared)
  s.score.inc(Rules.LCScoring[newCleared] * s.level)
  let newLevel = 1 + s.cleared div 10
  if newLevel > s.level:
    s.level = newLevel
    result = true

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

#  Threads  ###################################################################
proc ticker(arg: tuple[bus: ptr Chan[Message]; descendPeriod: ptr Atomic[int],
    gameOver: ptr Atomic[bool]]) {.thread.} =
  while not arg.gameOver[].load():
    sleep(arg.descendPeriod[].load())
    arg.bus[].send(msg(mkMovement, mTick))

proc waitForInput(arg: tuple[bus: ptr Chan[Message], opts: ptr Options,
    gameOver: ptr Atomic[bool]]) {.thread.} =
  var
    c = illwill.Key.None
    msg: Message
  let k = arg.opts[].kbdPreset
  while true:
    c = getKey()
    if not arg.gameOver[].load():
      if c in k.Left: arg.bus[].send msg(mkMovement, mLeft)
      elif c in k.Right: arg.bus[].send msg(mkMovement, mRight)
      elif c in k.Down: arg.bus[].send msg(mkMovement, mDown)
      elif c in k.Rotate: arg.bus[].send(
          msg(mkMovement, (if arg.opts[].rotation == CCW: mRotateCcw else: mRotateCw)))
      elif c in k.Drop: arg.bus[].send(
          msg(mkMovement, (if arg.opts[].hardDrop: mDrop else: mDown)))
      elif c in k.Hold: arg.bus[].send msg(mkCommand, cHold)
      elif c in k.Pause + {illwill.Key.CtrlZ}: arg.bus[].send msg(mkCommand, cPause)
      elif c in k.Exit:
          arg.bus[].send(msg(mkCommand, cQuit))
          when not defined(windows):
            break # on Windows we want to request a keypress after gameOver
      else: discard
    else: # if gameOver any input quits
      when defined(windows):
        if c notin {illwill.Key.None, illwill.Key.Mouse}:
          arg.bus[].send(msg(mkCommand, cQuit))
          break
      else:
        break
    sleep(UITick) # getKey is nonblocking

proc clearDelay(arg: tuple[bus: ptr Chan[Message]; level: Natural]) {.thread.} =
  arg.bus[].send(msg(mkCommand, cClearDelay)) # =pause
  sleep(toInt( 750.0 * (0.92 ^ arg.level) ))
  arg.bus[].send(msg(mkCommand, cClearDelay)) # =unpause

###############################################################################
proc main(state: sink State) =
  var
    updateDue = false
    msg: Message
    bus {.global.} = newChan[Message]() # Create a shared channel
    thInput: Thread[(ptr Chan[Message], ptr Options, ptr Atomic[bool])]
    thTicker: Thread[(ptr Chan[Message], ptr Atomic[int], ptr Atomic[bool])]
    thDelay: Thread[(ptr Chan[Message], Natural)]

  setControlCHook(proc(){.noconv.} = bus.send(msg(mkCommand, cQuit)))

  # Spawn threads
  thTicker.createThread(ticker, (addr bus, addr state.descendPeriod, addr state.gameOver))
  thInput.createThread(waitForInput, (addr bus, addr state.opts, addr state.gameOver))

  block mainLoop:
    while true:
      while bus.tryRecv(msg): # Receive and react to messages
        if msg.kind == mkCommand:
          case msg.command:
            of cPause: # pause publicly
              state.paused = not state.paused
              if state.paused:
                displayMsg(&"Paused. Press any of {{{state.opts.kbdPreset.Pause}}} to continue...")
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
              state.gameOver.store(true)
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
                state.gameOver.store(true)
                break mainLoop # Game Over!
            of mDrop:
              if state.opts.scoreDrops: state.stats.scoreHardDrop(state.curT.pos.y)
              state.curT = state.ghostT
              if not lockAndAdvance(state):
                state.gameOver.store(true)
                break mainLoop # Game Over!

      if updateDue:
        let cleared = state.pile.clearFull()
        if cleared > 0:
          if state.stats.updateAndLvlUp(cleared): # Leveling up
            state.descendPeriod.store(
              newDescendPeriod(state.stats.level, state.opts.speedCurve)
            )
          state.ghostT.updateGhost(state.curT, state.pile) # replace ghost to avoid lag
          if state.opts.delayOnClear:
            thDelay.createThread(clearDelay, (addr bus, Natural(state.stats.level)))
        var field = buildField(state.pile)
        if state.opts.ghost:
          field = field.addTetronimo(state.ghostT, ghost = true)
        field = field.addTetronimo(state.curT)
        state.ui.update(field)
        state.ui.refresh(state.opts.color)
        refreshStatus(state.nextT, state.heldT, state.stats, state.opts)
        updateDue = false

      sleep(UITick) # ui tick
  if state.gameOver.load():
    displayMsg(&"Game Over! Final{state.stats} \n\r{state.opts}")
    when defined(windows):
    # This block is known to be necessary only for cmd.exe
    # but we won't discriminate between Windows users
      echo("\rPress any key to exit...")
      while true: # thTicker might be running and channel buffer can be non-empty
        bus.recv(msg)
        if msg.kind == mkCommand and msg.command == cQuit:
          break
  thTicker.joinThread()
  thInput.joinThread()

proc initState(opts: sink Options, charset: sink string): State =
  var tetros = nextTetronimo
  let
    curT = tetros.next()
    nextT = tetros.next()
    stats = (cleared: 0, score: 0, level: 1)
    pile = initShuffleArray[FieldSize.h, array[FieldSize.w, Cell]]()
    heldT = (var t: Tetronimo; t.kind = rand(TO..TT); t)
    ui = uiInit(buildField(pile).addTetronimo(curT), charset)
    dp = Atomic(newDescendPeriod(1, opts.speedCurve))
  refreshStatus(nextT, heldT, stats, opts)
  State(tetros: tetros, pile: pile, stats: stats, curT: curT, nextT: nextT,
        heldT: heldT, opts: opts, ui: ui, descendPeriod: dp)

proc tetronimia(speedcurve: SpeedCurveKind = scNimia; rotation: RotationDir = CW;
    nohdrop: bool = false, noghost: bool = false, holdbox: bool = false,
    nolcdelay: bool = false, nodropreward: bool = false, nocolor: bool = false;
    charset = "", gameseed = "", kbd: KbdPreset = KbdPresetVim) =
  var opts: Options
  opts.speedCurve = speedcurve
  opts.rotation = rotation
  opts.hardDrop = not nohdrop
  opts.ghost = not noghost
  opts.holdBox = holdbox
  opts.delayOnClear = not nolcdelay
  opts.scoreDrops = not nodropreward
  opts.color = not nocolor
  opts.kbdPreset = kbd
  opts.seed = if gameseed != "": deserialize(gameseed)
              else: genSeed()
  randomize(opts.seed)
  illwillInit(fullscreen=false, mouse=false)
  main(initState(opts, charset))

when isMainModule:
  addExitProc(illwillDeinit)

  proc argParse(dst: var KbdPreset; dfl: KbdPreset; a: var ArgcvtParams): bool =
    dst = a.val.parseKbdPreset()
    return true

  proc argHelp(dfl: KbdPreset; a: var ArgcvtParams): seq[string] =
    argHelp($dfl, a)

  clCfg.hTabCols = @[clOptKeys, clDescrip] # hide types and default value columns
  clCfg.version = NimblePkgVersion
  dispatch(tetronimia, help = HelpS, short = ShortS, doc = DocS)
