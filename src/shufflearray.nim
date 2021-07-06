type ShuffleArray*[L: static[Natural], T] {.requiresInit.} = object
  idx: array[L, Natural]
  data: array[L, T]
  len: Natural

template resetIdx(a: var ShuffleArray) =
  for i, idx in a.idx.mpairs: idx = i

{.push warning[ProveInit]:off.}
func initShuffleArray*[L: static[Natural]; T](): ShuffleArray[L, T] {.noinit.} =
  result.len = 0
  for i in result.data.mitems:
    i = default(T)
  result.resetIdx()
{.pop.}

proc overwrite*(a: var ShuffleArray; val: openArray[ShuffleArray.T]) =
  ## Overwrites `a` with the contents of `val` and adjusts
  ## indexes and length accordingly.
  let vlen = val.len()
  if vlen != ShuffleArray.L:
    raise newException(IndexDefect, "Can't overwrite contents, lengths are not equal!")
  else:
    a.data = val
    a.resetIdx()
    a.len = vlen

func `[]`*(a: ShuffleArray; i: Natural): lent ShuffleArray.T =
  a.data[a.idx[i]]

proc `[]`*(a: var ShuffleArray; i: Natural): var ShuffleArray.T =
  a.data[a.idx[i]]

proc `[]=`*(a: var ShuffleArray; i: Natural; val: ShuffleArray.T) =
  a.data[a.idx[i]] = val

func len*(a: ShuffleArray): Natural = a.len

proc append*(a: var ShuffleArray; val: sink ShuffleArray.T = default(ShuffleArray.T)) =
  a[a.len] = val
  a.len.inc()

iterator items*(a: ShuffleArray): lent ShuffleArray.T =
  for i in 0..<a.len:
    yield a.data[a.idx[i]]

iterator pairs*(a: ShuffleArray): (Natural, lent ShuffleArray.T) =
  for i in 0.Natural..<a.len:
    yield (i, a.data[a.idx[i]])

proc removeUnsafe(a: var ShuffleArray; i: Natural) =
  #assert (i < a.len and a.len > 0):
  if i != a.len-1:
    let pop = a.idx[i]
    moveMem(addr a.idx[i], addr a.idx[i+1],
            sizeOf(ShuffleArray.T) * (a.len - 1 - i) 
    ) #a.idx[i..<a.len-1] = a.idx[i+1..<a.len]
    a.idx[a.len-1] = pop
  a.len.dec()

proc toSeq*(a: ShuffleArray): seq[ShuffleArray.T] {.noinit inline.} =
  result = newSeqOfCap[ShuffleArray.T](a.len)
  result.setLen(a.len)
  for i, val in a:
    result[i] = val

proc retainIf*(a: var ShuffleArray; 
               pred: proc(x: ShuffleArray.T): bool {.closure.}
               ): int {.inline.} =
  ## Removes the items of `a` if they fulfil the
  ## predicate `pred` (function that returns a `bool`).
  # TODO: optimize to detect continuous deletion candidates
  for i in countDown(a.len - 1, 0):
    if not pred(a[i]):
      a.removeUnsafe(i)
      result.inc()

when isMainModule:
  var test = initShuffleArray[4, int]()
  test.data = [1,2,3,4]
  test.resetIdx()
  test.len = 4
  block:
    var t = test
    t.removeUnsafe(1)
    assert t.data == [1,2,3,4]
    assert t.len == 3
    assert t.idx == [0.Natural,2,3,1]
    assert t.toSeq == @[1,3,4]
    
    t.append(9)
    assert t.len == 4
    assert t.toSeq == @[1,3,4,9]
    assert t.data == [1,9,3,4]

    t.removeUnsafe(0)
    assert t.idx == [2.Natural,3,1,0]
    assert t.len == 3
    assert t.toSeq == @[3,4,9]
    
    assert t.retainIf(proc(x:int): bool = x mod 3 != 0) == 2
    assert t.len == 1
    assert t.toSeq == @[4]
    assert t.idx == [3.Natural,2,1,0]
