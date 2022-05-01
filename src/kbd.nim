import std/[strformat]
from illwill import Key
from std/strutils import split, toLowerAscii

type
  KbdPreset* = object
    Left*: set[Key]
    Right*: set[Key]
    Down*: set[Key]
    Rotate*: set[Key]
    Drop*: set[Key]
    Hold*: set[Key]
    Pause*: set[Key]
    Exit*: set[Key]
  UserInput* = enum
    None = (-1, "None"),
    Left, Right, Down, Rotate, Drop, Hold, Pause, Exit

const
  KbdPresetVim* = KbdPreset(
    Left: {Key.H, Key.ShiftH}, Right: {Key.L, Key.ShiftL},
    Down: {Key.J, Key.ShiftJ, Key.Enter}, Rotate: {Key.K, Key.ShiftK, Key.Tab},
    Drop: {Key.D, Key.ShiftD, Key.Space}, Hold: {Key.F, Key.ShiftF},
    Pause: {Key.P, Key.ShiftP, Key.Escape}, Exit: {Key.Q, Key.ShiftQ}
  )
  KbdPresetEmacs* = KbdPreset(
    Left: {Key.B, Key.ShiftB}, Right: {Key.F, Key.ShiftF},
    Down: {Key.N, Key.ShiftN, Key.Enter}, Rotate: {Key.R, Key.ShiftR, Key.Tab},
    Drop: {Key.D, Key.ShiftD, Key.Space}, Hold: {Key.X, Key.ShiftX},
    Pause: {Key.P, Key.ShiftP, Key.Escape}, Exit: {Key.Q, Key.ShiftQ}
  )
  KbdPresetWASD* = KbdPreset(
    Left: {Key.A, Key.ShiftA}, Right: {Key.D, Key.ShiftD},
    Down: {Key.S, Key.ShiftS}, Rotate: {Key.W, Key.ShiftW, Key.Tab},
    Drop: {Key.E, Key.ShiftE, Key.Space}, Hold: {Key.Q, Key.ShiftQ},
    Pause: {Key.P, Key.ShiftP, Key.GraveAccent}, Exit: {Key.Escape}
  )
  KbdPresetCasual* = KbdPreset(
    Left: {Key.Left}, Right: {Key.Right},
    Down: {Key.Down}, Rotate: {Key.Up},
    Drop: {Key.Space}, Hold: {Key.Tab},
    Pause: {Key.Escape}, Exit: {Key.X, Key.ShiftX}
  )

proc `$`(x: set[Key]): string =
  var firstElement = true
  for key in x:
    if key in ShiftA..ShiftZ: continue
    else:
      if firstElement:
        firstElement = false
      else:
        result.add(",")
      if key.ord in 33..126:
        result.add(char(key.ord))
      else:
        result.add($key)
  result.toLowerAscii()

proc `$`*(x: KbdPreset): string =
  &"L:{x.Left};R:{x.Right};Dn:{x.Down};Rot:{x.Rotate};Drop:{x.Drop};Hold:{x.Hold};Ps:{x.Pause};Exit:{x.Exit}"

func toKey(c: int): Key =
  try:
    result = Key(c)
  except RangeDefect:  # ignore unknown keycodes
    result = Key.None

func parseKey(k: string): Key =
  if k.len == 1:
    case k[0]:
      of 'A'..'Z': toKey(k[0].ord - ord('a') + ord(Key.A))
      else: toKey(k[0].ord)
  else:
    case k:
      of "escape", "esc": Key.Escape
      of "tab": Key.Tab
      of "entr", "enter": Key.Enter
      of "space", "spc": Key.Space
      of "backspace", "bckspc": Key.Backspace
      of "up": Key.Up
      of "down", "dwn", "dn": Key.Down
      of "right", "rt": Key.Right
      of "left", "lt": Key.Left
      of "home": Key.Home
      of "insert", "ins": Key.Insert
      of "delete", "dlt": Key.Delete
      of "end": Key.End
      of "pageup", "pgup": Key.PageUp
      of "pagedown", "pgdown", "pgdwn", "pgdn": Key.PageDown
      of "ctrlc", "ctrl-c": Key.CtrlC
      of "backtick", "graveaccent": Key.GraveAccent
      else: Key.None

func parseUserInput(s: string): UserInput =
  case s:
    of "l", "left", "lt": UserInput.Left
    of "r", "rt", "right": UserInput.Right
    of "d", "dwn", "dn", "down": UserInput.Down
    of "rotate", "rot": UserInput.Rotate
    of "drop", "drp", "dr": UserInput.Drop
    of "hold", "h": UserInput.Hold
    of "pause", "ps": UserInput.Pause
    of "exit", "ex": UserInput.Exit
    else: UserInput.None

proc parseKbdPreset*(a: openArray[char]): KbdPreset =
  var s = newString(a.len)
  if a.len > 0: copyMem(addr(s[0]), a[0].unsafeAddr, a.len) # TODO: replace on #14810
  for c in s.mitems():
    if c in {'A'..'Z'}:
      c = char(uint8(c) xor 0b0010_0000'u8)
  case s:
    of "vim", "vi": KbdPresetVim
    of "emacs": KbdPresetVim
    of "wasd", "gamer": KbdPresetWASD
    of "casual": KbdPresetCasual
    else:
      var
        usedKeys: set[Key]
        unsetActions = {UserInput.Left..UserInput.Exit}
        action: UserInput
      for kvp in s.split(';'):
        #debugEcho "parsing : ", kv
        var i = 0
        while i < kvp.len and kvp[i] != ':':
          i.inc()
        action = parseUserInput(kvp[0..<i])
        if action == UserInput.None: quit(&"Can't parse keyboard preset action", 1)
        i.inc() # skip `:` separator
        #debugEcho " k: ", action
        let keys = kvp[i..kvp.high]
        #debugEcho " keys: ", keys
        var keySet: set[Key]
        for k in keys.split(','):
          let key = k.parseKey()
          if key != Key.None and key notin usedKeys:
            usedKeys.incl(key)
            keySet.incl(key)
        #debugEcho " ks: ", keySet
        if keySet == {} and action != UserInput.Exit: # CtrlC always exits
          quit(&"Keyboard preset error: No key given for \"{action}\"",1)
        case action:
          of UserInput.Left:   result.Left = keySet; unsetActions.excl(action)
          of UserInput.Right:  result.Right = keySet; unsetActions.excl(action)
          of UserInput.Down:   result.Down = keySet; unsetActions.excl(action)
          of UserInput.Rotate: result.Rotate = keySet; unsetActions.excl(action)
          of UserInput.Drop:   result.Drop = keySet; unsetActions.excl(action)
          of UserInput.Hold:   result.Hold = keySet; unsetActions.excl(action)
          of UserInput.Pause:  result.Pause = keySet; unsetActions.excl(action)
          of UserInput.Exit:   result.Exit = keySet; unsetActions.excl(action)
          else: quit(&"Unknown game action in keyboard preset: \"{action}\"", 1)
      if unsetActions != {} or unsetActions != {UserInput.Exit}:
        quit(&"Can't parse keyboard preset: no keys for \"{unsetActions}\"", 1)
      result

when isMainModule:
  for p in [KbdPresetEmacs, KbdPresetVim, KbdPresetCasual, KbdPresetWASD]:
    doAssert $p == $parseKbdPreset($p)
