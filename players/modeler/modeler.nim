import
  std/[algorithm, options, os, parseopt, random, strutils],
  whisky,
  bitworld/protocol,
  bitworld/pathfinding

const
  StagTileSize = 12
  TargetFps = 24
  WorldWidthTiles = 32
  WorldHeightTiles = 32

  BackgroundSpriteId = 3
  TreeSpriteId = 1
  RockSpriteId = 2
  PreySpriteBase = 10
  PlayerSpriteBase = 100
  PlayerSpriteEnd = PlayerSpriteBase + 8 * 4

  PlayerObjectBase = 5000
  KillGlowObjectBase = 7000      # +playerArrayIndex when a player participated in a kill
  KillGlowSpriteId = 5
  BackgroundObjectBase = 8000
  PreyObjectBase = 10000
  IndicatorObjectBase = 9000
  IndicatorSpriteBase = 20

  MaxPlayerSlots = 64
  MaxPreySlots = 256
  MaxPreyCount = 64
  MaxBackgroundIndex = WorldWidthTiles * WorldHeightTiles
  MaxDrainMessages = 256
  ConnectRetryDelayMs = 250
  WebSocketPath = "/player"


type
  PreyKind = enum
    Rabbit
    Boar
    Stag
    Moose
    Elephant

  SpriteKind = enum
    SpriteUnknown
    SpriteBackground
    SpriteTree
    SpriteRock
    SpritePrey
    SpritePlayer
    SpriteIndicator

  SpriteInfo = object
    defined: bool
    width: int
    height: int
    kind: SpriteKind

  ObjectState = object
    present: bool
    x: int
    y: int
    spriteId: int

  PreySight = object
    found: bool
    objectId: int
    kind: PreyKind
    tileX: int
    tileY: int

  PlayerSight = object
    found: bool
    objectId: int
    color: int
    tileX: int
    tileY: int

  BotMode = enum
    ModeExplore
    ModeHunt

  PreyMemory = object
    ## Last known position of a visible prey, by objectId. Used so when
    ## the prey vanishes (server stops sending it) and a kill glow
    ## appears at that spot, we can attribute the capture.
    present: bool
    kind: PreyKind
    tileX: int
    tileY: int

  ColorMemory = object
    ## What we've learned about a particular player color.
    seenCatch: set[PreyKind]                   # observed them participate in catching
    attempts: array[PreyKind, int]              # ticks spent adjacent to a kind with them adjacent too
    failures: array[PreyKind, int]              # adjacent-with-them attempts that timed out without capture

  Bot = object
    sprites: seq[SpriteInfo]
    objects: seq[ObjectState]
    cameraX: int
    cameraY: int
    cameraKnown: bool
    frameTick: int
    selfObjectId: int
    selfTileX: int
    selfTileY: int
    haveSelf: bool
    lastMask: uint8
    mode: BotMode
    exploreTargetX: int
    exploreTargetY: int
    exploreTargetAge: int
    obstacleMap: ObstacleMap
    posHistory: array[4, tuple[x, y: int]]
    posHistoryIdx: int
    posHistoryCount: int
    stuckCount: int
    lastSentNonZero: bool
    lastAdjacentPreyId: int
    adjacentWaitTicks: int
    energy: int
    energyKnown: bool
    resting: bool
    # Modeling state.
    colorMem: array[20, ColorMemory]            # NumPlayerColors = 20 on server
    preyMem: array[256, PreyMemory]             # MaxPreySlots = 256
    lastKillGlowPresent: array[64, bool]        # MaxPlayerSlots = 64
    # Track our current sustained adjacency, for accounting attempts.
    curAdjacentPreyObjId: int
    curAdjacentPreyKind: PreyKind
    curAdjacentTicks: int

proc readU16(blob: string, offset: int): int =
  int(uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8))

proc readI16(blob: string, offset: int): int =
  let value = uint16(blob[offset].uint8) or
    (uint16(blob[offset + 1].uint8) shl 8)
  int(cast[int16](value))

proc readU32(blob: string, offset: int): int =
  int(uint32(blob[offset].uint8) or
    (uint32(blob[offset + 1].uint8) shl 8) or
    (uint32(blob[offset + 2].uint8) shl 16) or
    (uint32(blob[offset + 3].uint8) shl 24))

proc ensureSprite(bot: var Bot, spriteId: int) =
  if spriteId >= bot.sprites.len:
    bot.sprites.setLen(spriteId + 1)

proc ensureObject(bot: var Bot, objectId: int) =
  if objectId >= bot.objects.len:
    bot.objects.setLen(objectId + 1)

proc classifySprite(spriteId: int): SpriteKind =
  if spriteId == BackgroundSpriteId: return SpriteBackground
  if spriteId == TreeSpriteId: return SpriteTree
  if spriteId == RockSpriteId: return SpriteRock
  if spriteId >= PreySpriteBase and spriteId < PreySpriteBase + 5: return SpritePrey
  if spriteId >= PlayerSpriteBase and spriteId < PlayerSpriteEnd: return SpritePlayer
  if spriteId >= IndicatorSpriteBase and spriteId < IndicatorSpriteBase + 3: return SpriteIndicator
  SpriteUnknown

proc applySpritePacket(bot: var Bot, packet: string): bool =
  var offset = 0
  while offset < packet.len:
    let messageType = packet[offset].uint8
    inc offset
    case messageType
    of 0x01:
      if offset + 10 > packet.len: return false
      let
        spriteId = packet.readU16(offset)
        width = packet.readU16(offset + 2)
        height = packet.readU16(offset + 4)
        compressedLen = packet.readU32(offset + 6)
      offset += 10
      if compressedLen < 0 or offset + compressedLen + 2 > packet.len: return false
      offset += compressedLen
      let labelLen = packet.readU16(offset)
      offset += 2
      if offset + labelLen > packet.len: return false
      offset += labelLen
      bot.ensureSprite(spriteId)
      bot.sprites[spriteId] = SpriteInfo(
        defined: true, width: width, height: height,
        kind: classifySprite(spriteId)
      )
    of 0x02:
      if offset + 11 > packet.len: return false
      let
        objectId = packet.readU16(offset)
        x = packet.readI16(offset + 2)
        y = packet.readI16(offset + 4)
        spriteId = packet.readU16(offset + 9)
      offset += 11
      bot.ensureObject(objectId)
      bot.objects[objectId] = ObjectState(present: true, x: x, y: y, spriteId: spriteId)
    of 0x03:
      if offset + 2 > packet.len: return false
      let objectId = packet.readU16(offset)
      offset += 2
      if objectId >= 0 and objectId < bot.objects.len:
        bot.objects[objectId].present = false
    of 0x04:
      for item in bot.objects.mitems:
        item.present = false
      bot.cameraKnown = false
      bot.haveSelf = false
      bot.selfObjectId = -1
    of 0x05:
      if offset + 5 > packet.len: return false
      offset += 5
    of 0x06:
      if offset + 3 > packet.len: return false
      offset += 3
    of 0x07:
      if offset + 2 > packet.len: return false
      bot.selfObjectId = packet.readU16(offset)
      offset += 2
    of 0x08:
      if offset + 2 > packet.len: return false
      bot.energy = packet.readU16(offset)
      bot.energyKnown = true
      offset += 2
    else:
      return false
  true

proc spriteInfo(bot: Bot, spriteId: int): SpriteInfo =
  if spriteId >= 0 and spriteId < bot.sprites.len:
    return bot.sprites[spriteId]
  SpriteInfo()

proc objectPresent(bot: Bot, objectId: int): bool =
  objectId >= 0 and objectId < bot.objects.len and bot.objects[objectId].present

proc updateCamera(bot: var Bot) =
  bot.cameraKnown = false
  for i in 0 ..< MaxBackgroundIndex:
    let objectId = BackgroundObjectBase + i
    if not bot.objectPresent(objectId):
      continue
    let
      state = bot.objects[objectId]
      tx = i mod WorldWidthTiles
      ty = i div WorldWidthTiles
    bot.cameraX = tx * StagTileSize - state.x
    bot.cameraY = ty * StagTileSize - state.y
    bot.cameraKnown = true
    return

proc visiblePlayers(bot: Bot): seq[PlayerSight] =
  for i in 0 ..< MaxPlayerSlots:
    let objectId = PlayerObjectBase + i
    if not bot.objectPresent(objectId):
      continue
    let
      state = bot.objects[objectId]
      sprite = bot.spriteInfo(state.spriteId)
    if not sprite.defined or sprite.kind != SpritePlayer:
      continue
    let
      worldX = bot.cameraX + state.x
      worldY = bot.cameraY + state.y
      colorSlot = (state.spriteId - PlayerSpriteBase) div 4
    result.add(PlayerSight(
      found: true, objectId: objectId, color: colorSlot,
      tileX: worldX div StagTileSize,
      tileY: worldY div StagTileSize
    ))

proc visiblePrey(bot: Bot): seq[PreySight] =
  for i in 0 ..< MaxPreySlots:
    let objectId = PreyObjectBase + i
    if not bot.objectPresent(objectId):
      continue
    let
      state = bot.objects[objectId]
      sprite = bot.spriteInfo(state.spriteId)
    if not sprite.defined or sprite.kind != SpritePrey:
      continue
    let
      worldX = bot.cameraX + state.x
      worldY = bot.cameraY + state.y
      kindOrd = state.spriteId - PreySpriteBase
      preyKind = if kindOrd >= 0 and kindOrd <= 4: PreyKind(kindOrd) else: Rabbit
    result.add(PreySight(
      found: true, objectId: objectId, kind: preyKind,
      tileX: (worldX + StagTileSize div 2) div StagTileSize,
      tileY: (worldY + StagTileSize div 2) div StagTileSize
    ))

proc identifySelf(bot: var Bot, players: openArray[PlayerSight]) =
  bot.haveSelf = false
  if bot.selfObjectId < 0: return
  for p in players:
    if p.objectId == bot.selfObjectId:
      bot.haveSelf = true
      bot.selfTileX = p.tileX
      bot.selfTileY = p.tileY
      return

proc updateStuckState(bot: var Bot, mask: uint8) =
  if not bot.haveSelf: return
  let lastIdx = (bot.posHistoryIdx + bot.posHistoryCount - 1 + 4) mod 4
  let posChanged = bot.posHistoryCount == 0 or
    bot.selfTileX != bot.posHistory[lastIdx].x or
    bot.selfTileY != bot.posHistory[lastIdx].y
  if posChanged:
    bot.posHistory[bot.posHistoryIdx] = (bot.selfTileX, bot.selfTileY)
    bot.posHistoryIdx = (bot.posHistoryIdx + 1) mod 4
    if bot.posHistoryCount < 4:
      inc bot.posHistoryCount
    bot.stuckCount = 0
  elif mask != 0:
    inc bot.stuckCount
  bot.lastSentNonZero = mask != 0

proc updateObstacleMap(bot: var Bot) =
  if not bot.cameraKnown: return
  for i in 0 ..< MaxBackgroundIndex:
    let objectId = BackgroundObjectBase + i
    if not bot.objectPresent(objectId): continue
    let
      state = bot.objects[objectId]
      sprite = bot.spriteInfo(state.spriteId)
      tx = i mod WorldWidthTiles
      ty = i div WorldWidthTiles
    if not sprite.defined: continue
    case sprite.kind
    of SpriteTree, SpriteRock:
      bot.obstacleMap.markTile(tx, ty, TileBlocked)
    of SpriteBackground:
      bot.obstacleMap.markTile(tx, ty, TileClear)
    else:
      discard

proc navigate(bot: var Bot, targetX, targetY: int): uint8 =
  if bot.stuckCount >= 15:
    let mask = unstickStep(bot.obstacleMap, bot.selfTileX, bot.selfTileY, bot.frameTick)
    bot.updateStuckState(mask)
    return mask
  let mask = pathStep(bot.obstacleMap, bot.selfTileX, bot.selfTileY, targetX, targetY)
  bot.updateStuckState(mask)
  mask

proc pickExploreTarget(bot: var Bot) =
  const margin = 4
  let quadrant = (bot.frameTick div 120) mod 4
  case quadrant
  of 0: bot.exploreTargetX = margin + 4; bot.exploreTargetY = margin + 4
  of 1: bot.exploreTargetX = WorldWidthTiles - margin - 4; bot.exploreTargetY = margin + 4
  of 2: bot.exploreTargetX = WorldWidthTiles - margin - 4; bot.exploreTargetY = WorldHeightTiles - margin - 4
  of 3: bot.exploreTargetX = margin + 4; bot.exploreTargetY = WorldHeightTiles - margin - 4
  else: discard
  bot.exploreTargetAge = 0

proc chebyshev(ax, ay, bx, by: int): int =
  max(abs(ax - bx), abs(ay - by))

proc requiredHunters(kind: PreyKind): int =
  case kind
  of Rabbit: 1
  of Boar: 2
  of Stag: 2
  of Moose: 3
  of Elephant: 4

proc scoreReward(kind: PreyKind): int =
  ## Mirrors server stag_hunt.nim constants.
  case kind
  of Rabbit: 1
  of Boar: 3
  of Stag: 5
  of Moose: 10
  of Elephant: 18

proc allyTrust(mem: ColorMemory, kind: PreyKind): float =
  ## How much do we believe this color can cooperate with us to catch
  ## this kind? Starts optimistic (0.5) for any unseen pair, climbs to
  ## ~1.0 after one observed success, decays toward 0 after several
  ## failed adjacency attempts without a success.
  if kind in mem.seenCatch:
    return 1.0
  let
    fails = mem.failures[kind]
    attempts = mem.attempts[kind]
  if attempts == 0:
    return 0.5
  # 5+ failed attempts with no observed success → distrust.
  if fails >= 5:
    return 0.05
  # Modest distrust accumulates with each unproductive attempt.
  result = max(0.1, 0.5 - 0.08 * float(fails))

type
  OccupiedSides = object
    n, s, e, w: bool

proc occupiedSidesOf(
  preyX, preyY: int,
  players: openArray[PlayerSight]
): OccupiedSides =
  for player in players:
    if player.tileX == preyX and player.tileY == preyY - 1:
      result.n = true
    elif player.tileX == preyX and player.tileY == preyY + 1:
      result.s = true
    elif player.tileX == preyX + 1 and player.tileY == preyY:
      result.e = true
    elif player.tileX == preyX - 1 and player.tileY == preyY:
      result.w = true

proc sideOccupied(sides: OccupiedSides, ord: int): bool =
  case ord
  of 0: sides.n
  of 1: sides.e
  of 2: sides.s
  of 3: sides.w
  else: true

proc bestSide(
  selfX, selfY, preyX, preyY: int,
  kind: PreyKind,
  selfObjectId: int,
  players: openArray[PlayerSight]
): tuple[x, y: int, found: bool] =
  ## Pick a side appropriate to the prey kind:
  ## - Stag: prefer the side opposite an already-claimed one (Stag needs
  ##   opposing sides). Fall back to tile-parity axis bias.
  ## - Moose / Elephant: rank-based assignment (sorted-objectId rank
  ##   maps to side N/E/S/W) so multiple hunters with the same view
  ##   spread out.
  ## - Boar: prefer a side perpendicular to an already-claimed one.
  ## - Rabbit: any cardinal side.
  let sides = occupiedSidesOf(preyX, preyY, players)
  const offsets = [(0, -1), (1, 0), (0, 1), (-1, 0)]
  case kind
  of Stag:
    let
      selfIsN = (selfX == preyX and selfY == preyY - 1)
      selfIsS = (selfX == preyX and selfY == preyY + 1)
      selfIsE = (selfX == preyX + 1 and selfY == preyY)
      selfIsW = (selfX == preyX - 1 and selfY == preyY)
    if sides.n and not sides.s and not selfIsN:
      return (preyX, preyY + 1, true)
    if sides.s and not sides.n and not selfIsS:
      return (preyX, preyY - 1, true)
    if sides.e and not sides.w and not selfIsE:
      return (preyX - 1, preyY, true)
    if sides.w and not sides.e and not selfIsW:
      return (preyX + 1, preyY, true)
    let vertical = ((preyX + preyY) and 1) == 0
    if vertical: return (preyX, preyY - 1, true)
    else: return (preyX + 1, preyY, true)
  of Boar:
    # Perpendicular to whichever side is claimed.
    if sides.n or sides.s:
      if not sides.e: return (preyX + 1, preyY, true)
      if not sides.w: return (preyX - 1, preyY, true)
    if sides.e or sides.w:
      if not sides.n: return (preyX, preyY - 1, true)
      if not sides.s: return (preyX, preyY + 1, true)
    # Nothing claimed — pick by tile parity for consistency.
    let vertical = ((preyX + preyY) and 1) == 0
    if vertical: return (preyX, preyY - 1, true)
    else: return (preyX + 1, preyY, true)
  of Moose, Elephant:
    var rank = 0
    for pl in players:
      if pl.objectId == selfObjectId: continue
      if pl.objectId < selfObjectId: inc rank
    let primary = rank mod 4
    for offset in 0 ..< 4:
      let ord = (primary + offset) mod 4
      if sideOccupied(sides, ord): continue
      let
        sx = preyX + offsets[ord][0]
        sy = preyY + offsets[ord][1]
      return (sx, sy, true)
    return (preyX, preyY - 1, true)  # all sides occupied; shouldn't happen
  of Rabbit:
    # Closest unoccupied cardinal that we can reach.
    var bestDist = high(int)
    for ord in 0 ..< 4:
      if sideOccupied(sides, ord): continue
      let
        sx = preyX + offsets[ord][0]
        sy = preyY + offsets[ord][1]
        d = abs(selfX - sx) + abs(selfY - sy)
      if d < bestDist:
        bestDist = d
        result = (sx, sy, true)

proc findKillSpot(bot: Bot): tuple[x, y: int, found: bool] =
  ## Scan for 1-dot indicator adjacent to self — stepping there completes a capture.
  const IndicatorTileOffset = (StagTileSize - 4) div 2  # 4px indicator centered in 12px tile
  for preyIdx in 0 ..< MaxPreyCount:
    for sideOrd in 0 ..< 4:
      let objectId = IndicatorObjectBase + preyIdx * 4 + sideOrd
      if not bot.objectPresent(objectId): continue
      let state = bot.objects[objectId]
      let sprite = bot.spriteInfo(state.spriteId)
      if not sprite.defined or sprite.kind != SpriteIndicator: continue
      # Only care about 1-dot (immediate kill)
      if state.spriteId != IndicatorSpriteBase: continue
      let
        worldX = bot.cameraX + state.x - IndicatorTileOffset
        worldY = bot.cameraY + state.y - IndicatorTileOffset
        tileX = worldX div StagTileSize
        tileY = worldY div StagTileSize
        dx = abs(bot.selfTileX - tileX)
        dy = abs(bot.selfTileY - tileY)
      # Adjacent (1 step away) or already there
      if (dx + dy) <= 2:
        return (tileX, tileY, true)
  (0, 0, false)

proc detectCaptures(bot: var Bot, prey: openArray[PreySight], players: openArray[PlayerSight]) =
  ## Look for the rising edge of any KillGlow object. The glow appears
  ## at a player tile when that player participated in a capture. The
  ## captured prey kind is inferred from a prey we *had* in preyMem last
  ## frame and is now missing within 1 tile of the glow.
  # Track who currently has a kill glow.
  var currentGlow: array[64, bool]
  for i in 0 ..< 64:
    let glowObj = KillGlowObjectBase + i
    if bot.objectPresent(glowObj):
      let st = bot.objects[glowObj]
      if st.spriteId == KillGlowSpriteId:
        currentGlow[i] = true
  # Build a set of currently-visible prey objectIds.
  var presentNow: array[256, bool]
  for p in prey:
    let idx = p.objectId - PreyObjectBase
    if idx >= 0 and idx < 256: presentNow[idx] = true
  # For each newly-arrived glow, find a vanished prey nearby.
  for i in 0 ..< 64:
    if not currentGlow[i] or bot.lastKillGlowPresent[i]:
      continue
    let playerObj = PlayerObjectBase + i
    if not bot.objectPresent(playerObj): continue
    let pState = bot.objects[playerObj]
    let
      colorSlot = (pState.spriteId - PlayerSpriteBase) div 4
      tileX = (bot.cameraX + pState.x) div StagTileSize
      tileY = (bot.cameraY + pState.y) div StagTileSize
    # Look for a known-prey that disappeared this frame and is within 1 tile.
    var caughtKind: PreyKind
    var found = false
    for idx in 0 ..< 256:
      if not bot.preyMem[idx].present: continue
      if presentNow[idx]: continue
      let dx = abs(bot.preyMem[idx].tileX - tileX)
      let dy = abs(bot.preyMem[idx].tileY - tileY)
      if dx <= 1 and dy <= 1:
        caughtKind = bot.preyMem[idx].kind
        found = true
        break
    if found and colorSlot >= 0 and colorSlot < 20:
      bot.colorMem[colorSlot].seenCatch.incl(caughtKind)
  # Refresh memory with the current frame's prey.
  for idx in 0 ..< 256:
    bot.preyMem[idx].present = false
  for p in prey:
    let idx = p.objectId - PreyObjectBase
    if idx >= 0 and idx < 256:
      bot.preyMem[idx] = PreyMemory(
        present: true, kind: p.kind, tileX: p.tileX, tileY: p.tileY
      )
  # Save glow state for next frame's edge detection.
  for i in 0 ..< 64:
    bot.lastKillGlowPresent[i] = currentGlow[i]

proc updateAttempts(bot: var Bot, prey: openArray[PreySight], players: openArray[PlayerSight]) =
  ## Track sustained "I'm adjacent to a prey with at least one ally
  ## also adjacent" episodes. When the episode ends without a capture
  ## (the prey vanished or I moved away first), credit a failure to
  ## the cooperating allies' colors.
  var stillAdjacent = -1
  var adjKind = Rabbit
  for p in prey:
    let dx = abs(bot.selfTileX - p.tileX)
    let dy = abs(bot.selfTileY - p.tileY)
    if (dx == 1 and dy == 0) or (dx == 0 and dy == 1):
      stillAdjacent = p.objectId
      adjKind = p.kind
      break

  if stillAdjacent < 0:
    # Episode ended (we left, or all adjacent prey vanished).
    if bot.curAdjacentPreyObjId >= 0 and bot.curAdjacentTicks >= 10:
      # Did the prey escape (still on-map, just not adjacent to us)? If
      # we can find it in preyMem still present, it escaped. If not, it
      # was either captured (handled in detectCaptures) or out of view.
      let idx = bot.curAdjacentPreyObjId - PreyObjectBase
      let escaped = idx >= 0 and idx < 256 and bot.preyMem[idx].present
      if escaped:
        # Credit failure to allies who were adjacent during the episode.
        # We approximate by penalizing currently-visible allies that were
        # close — better than nothing.
        for pl in players:
          if pl.objectId == bot.selfObjectId: continue
          let dd = chebyshev(pl.tileX, pl.tileY, bot.preyMem[idx].tileX, bot.preyMem[idx].tileY)
          if dd <= 2 and pl.color >= 0 and pl.color < 20:
            inc bot.colorMem[pl.color].failures[bot.curAdjacentPreyKind]
    bot.curAdjacentPreyObjId = -1
    bot.curAdjacentTicks = 0
  else:
    if bot.curAdjacentPreyObjId == stillAdjacent:
      inc bot.curAdjacentTicks
    else:
      bot.curAdjacentPreyObjId = stillAdjacent
      bot.curAdjacentPreyKind = adjKind
      bot.curAdjacentTicks = 1
    # Credit attempt to any adjacent ally.
    for pl in players:
      if pl.objectId == bot.selfObjectId: continue
      let pdx = abs(pl.tileX - bot.selfTileX)
      let pdy = abs(pl.tileY - bot.selfTileY)
      if (pdx + pdy) <= 3 and pl.color >= 0 and pl.color < 20:
        # Count adjacency frames sparingly (every 6 frames = once per
        # quarter-second) so attempts and failures stay comparable.
        if bot.frameTick mod 6 == 0:
          inc bot.colorMem[pl.color].attempts[bot.curAdjacentPreyKind]

proc chooseHunt(
  bot: Bot,
  prey: openArray[PreySight],
  players: openArray[PlayerSight]
): tuple[target: PreySight, found: bool] =
  ## Pick the prey whose expected reward × estimated-success-rate is
  ## highest, given the visible allies and what we know about them.
  ## Search distance is bounded by Chebyshev (matches viewport).
  var bestScore = -1.0
  for p in prey:
    let required = requiredHunters(p.kind)
    # Count visible cooperators (ourselves + allies). If the count is
    # below `required`, no realistic capture, skip.
    var alliesNear: seq[int] = @[]  # color slots
    for pl in players:
      if pl.objectId == bot.selfObjectId: continue
      let pd = chebyshev(pl.tileX, pl.tileY, p.tileX, p.tileY)
      if pd <= 6 and pl.color >= 0 and pl.color < 20:
        alliesNear.add(pl.color)
    if 1 + alliesNear.len < required:
      continue
    # Pick the best `required-1` allies by trust.
    var trusts: seq[float] = @[]
    for c in alliesNear:
      trusts.add(allyTrust(bot.colorMem[c], p.kind))
    trusts.sort(SortOrder.Descending)
    var cooperationProb = 1.0
    for k in 0 ..< (required - 1):
      cooperationProb *= trusts[k]
    let
      myDist = chebyshev(bot.selfTileX, bot.selfTileY, p.tileX, p.tileY)
      distancePenalty = 1.0 / float(myDist + 2)
      reward = float(scoreReward(p.kind))
      score = reward * cooperationProb * distancePenalty
    if score > bestScore:
      bestScore = score
      result.target = p
      result.found = true

proc decideMask(bot: var Bot): uint8 =
  bot.updateCamera()
  if not bot.cameraKnown: return 0
  let players = bot.visiblePlayers()
  bot.identifySelf(players)
  if not bot.haveSelf: return 0
  bot.updateObstacleMap()

  let prey = bot.visiblePrey()

  # Modeling updates (catches first so a successful adjacency doesn't
  # roll into a failure attribution).
  bot.detectCaptures(prey, players)
  bot.updateAttempts(prey, players)

  # Priority 1: step into a 1-dot indicator (always a win, regardless
  # of strategy).
  let killSpot = bot.findKillSpot()
  if killSpot.found:
    if bot.selfTileX == killSpot.x and bot.selfTileY == killSpot.y:
      bot.updateStuckState(0)
      return 0
    return bot.navigate(killSpot.x, killSpot.y)

  if bot.energyKnown:
    if bot.energy < 30: bot.resting = true
    elif bot.energy >= 60: bot.resting = false
  if bot.resting:
    bot.updateStuckState(0)
    return 0

  # If we're already adjacent to a prey we *think* we can catch with
  # currently-visible allies, hold there.
  for p in prey:
    let dx = abs(bot.selfTileX - p.tileX)
    let dy = abs(bot.selfTileY - p.tileY)
    if not ((dx == 1 and dy == 0) or (dx == 0 and dy == 1)): continue
    let required = requiredHunters(p.kind)
    if required == 1:
      # Server captures it this tick anyway; hold to make sure.
      bot.mode = ModeHunt
      bot.updateStuckState(0)
      return 0
    var qualifiedAllies = 0
    for pl in players:
      if pl.objectId == bot.selfObjectId: continue
      if pl.color < 0 or pl.color >= 20: continue
      let pd = chebyshev(pl.tileX, pl.tileY, p.tileX, p.tileY)
      if pd <= 4 and allyTrust(bot.colorMem[pl.color], p.kind) >= 0.4:
        inc qualifiedAllies
    if 1 + qualifiedAllies >= required:
      bot.mode = ModeHunt
      bot.updateStuckState(0)
      return 0

  let pick = chooseHunt(bot, prey, players)
  if pick.found:
    bot.mode = ModeHunt
    let side = bestSide(
      bot.selfTileX, bot.selfTileY, pick.target.tileX, pick.target.tileY,
      pick.target.kind, bot.selfObjectId, players
    )
    if side.found:
      return bot.navigate(side.x, side.y)
    return bot.navigate(pick.target.tileX, pick.target.tileY)

  # Nothing worth hunting. Cluster a bit (so when prey appears we have
  # cooperators in view), otherwise patrol quadrants.
  bot.mode = ModeExplore
  var nearestAlly: PlayerSight
  var nearestAllyDist = high(int)
  for pl in players:
    if pl.objectId == bot.selfObjectId: continue
    let d = chebyshev(bot.selfTileX, bot.selfTileY, pl.tileX, pl.tileY)
    if d < nearestAllyDist:
      nearestAllyDist = d
      nearestAlly = pl
  if nearestAlly.found and nearestAllyDist > 3:
    return bot.navigate(nearestAlly.tileX, nearestAlly.tileY)

  inc bot.exploreTargetAge
  let atTarget = (bot.selfTileX == bot.exploreTargetX and
                  bot.selfTileY == bot.exploreTargetY)
  if atTarget or bot.exploreTargetAge > 200 or bot.stuckCount > 30:
    bot.pickExploreTarget()

  bot.navigate(bot.exploreTargetX, bot.exploreTargetY)

proc playerInputBlob(mask: uint8): string =
  blobFromBytes([0x84'u8, mask and 0x7f'u8])

proc queryEscape(value: string): string =
  const Hex = "0123456789ABCDEF"
  for ch in value:
    if ch.isAlphaNumeric() or ch in {'-', '_', '.', '~'}:
      result.add(ch)
    else:
      let byte = ord(ch)
      result.add('%')
      result.add(Hex[(byte shr 4) and 0x0f])
      result.add(Hex[byte and 0x0f])

proc withPath(url, path: string): string =
  let schemePos = url.find("://")
  if schemePos < 0: return url
  let pathStart = url.find('/', schemePos + 3)
  if pathStart >= 0: return url
  url & path

proc addQueryParam(url, key, value: string): string =
  if value.len == 0: return url
  result = url
  if '?' in result: result.add('&')
  else: result.add('?')
  result.add(key)
  result.add('=')
  result.add(value.queryEscape())

proc connectUrl(address, url, name, token: string, port, slot: int): string =
  if url.len > 0:
    result = url.withPath(WebSocketPath)
  else:
    result = "ws://" & address & ":" & $port & WebSocketPath
  result = result.addQueryParam("name", name)
  if slot >= 0:
    result = result.addQueryParam("slot", $slot)
  if token.len > 0:
    result = result.addQueryParam("token", token)

proc initBot(): Bot =
  result.selfObjectId = -1
  result.lastMask = 0xff'u8
  result.mode = ModeExplore
  result.exploreTargetX = MapWidth div 2
  result.exploreTargetY = MapHeight div 2
  result.exploreTargetAge = 0
  result.posHistoryIdx = 0
  result.posHistoryCount = 0
  result.stuckCount = 0
  result.lastSentNonZero = false
  result.lastAdjacentPreyId = -1
  result.adjacentWaitTicks = 0
  result.curAdjacentPreyObjId = -1

proc acceptServerMessage(ws: WebSocket, message: Message, bot: var Bot): bool =
  case message.kind
  of BinaryMessage:
    result = bot.applySpritePacket(message.data)
    if result: inc bot.frameTick
  of Ping:
    ws.send(message.data, Pong)
  of TextMessage, Pong:
    discard

proc receiveUpdates(ws: WebSocket, bot: var Bot): bool =
  let firstMessage = ws.receiveMessage(-1)
  if firstMessage.isNone: return false
  if ws.acceptServerMessage(firstMessage.get, bot):
    result = true
  var drained = 0
  while drained < MaxDrainMessages:
    let message = ws.receiveMessage(0)
    if message.isNone: break
    if ws.acceptServerMessage(message.get, bot):
      result = true
    inc drained

proc runBot(
  address = DefaultHost,
  port = DefaultPort,
  url = "",
  name = "modeler",
  token = "",
  slot = -1
) =
  let endpoint = connectUrl(address, url, name, token, port, slot)
  while true:
    try:
      echo "modeler connecting to ", endpoint
      var bot = initBot()
      let ws = newWebSocket(endpoint)
      var lastMask = 0xff'u8
      while true:
        if not ws.receiveUpdates(bot):
          continue
        let mask = bot.decideMask()
        if mask != lastMask:
          ws.send(playerInputBlob(mask), BinaryMessage)
          lastMask = mask
    except CatchableError as e:
      echo "modeler reconnecting after error: ", e.msg
      sleep(ConnectRetryDelayMs)

when isMainModule:
  randomize()
  var
    address = DefaultHost
    port = DefaultPort
    url = getEnv("COGAMES_ENGINE_WS_URL")
    name = "modeler"
    token = ""
    slot = -1

  for kind, key, value in getopt():
    case kind
    of cmdLongOption:
      case key
      of "address": address = value
      of "port": port = parseInt(value)
      of "url": url = value
      of "name": name = value
      of "token": token = value
      of "slot": slot = parseInt(value)
      else:
        raise newException(ValueError, "Unknown option: --" & key)
    of cmdArgument, cmdShortOption:
      raise newException(ValueError, "Unexpected argument: " & key)
    of cmdEnd:
      discard

  runBot(address, port, url, name, token, slot)
