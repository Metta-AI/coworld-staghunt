import
  std/[options, os, parseopt, random, strutils],
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
    tileX: int
    tileY: int

  BotMode = enum
    ModeExplore
    ModeHunt

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
    rechargingUntil: int  # frameTick at which to resume hunting after retreat

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

proc refreshEnergyFromHud(bot: var Bot) =
  ## Decodes self-energy from the HUD digit sprites the server places at
  ## y=7 (right of the energy icon) every per-player frame. Browsers
  ## render those digits as the visible energy readout; we re-decode
  ## them as an integer, so bots and humans observe the same world
  ## through the same wire protocol -- no custom packet needed.
  const
    EnergyHudY = 7
    DigitSpriteBase = 30   # sprite ids 30..39 are digits '0'..'9'
    DigitSpriteMax = 39
    DigitStride = 4        # DigitSpriteWidth(3) + 1 pixel gap
    DigitStartX = 5        # first digit lives at (5, 7); icon at (1, 7)
  var
    digits: array[6, int]
    maxIdx = -1
  for obj in bot.objects:
    if not obj.present or obj.y != EnergyHudY:
      continue
    if obj.spriteId < DigitSpriteBase or obj.spriteId > DigitSpriteMax:
      continue
    let idx = (obj.x - DigitStartX) div DigitStride
    if idx < 0 or idx >= digits.len:
      continue
    digits[idx] = obj.spriteId - DigitSpriteBase
    if idx > maxIdx:
      maxIdx = idx
  if maxIdx < 0:
    return
  var value = 0
  for i in 0 .. maxIdx:
    value = value * 10 + digits[i]
  bot.energy = value
  bot.energyKnown = true

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
    else:
      return false
  bot.refreshEnergyFromHud()
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
    result.add(PlayerSight(
      found: true, objectId: objectId,
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

proc navigateAvoiding(
  bot: var Bot, targetX, targetY: int,
  blocked: openArray[tuple[x, y: int]]
): uint8 =
  ## BFS that also treats `blocked` tiles as impassable for this call
  ## only. Used to route around visible allies — without this the path
  ## planner happily routes through an ally tile, the server denies the
  ## step, and the bot bounces forever.
  var saved: seq[tuple[x, y: int, prev: TileStatus]] = @[]
  for b in blocked:
    if not inBounds(b.x, b.y): continue
    if b.x == targetX and b.y == targetY: continue  # the target itself
    if b.x == bot.selfTileX and b.y == bot.selfTileY: continue
    saved.add((b.x, b.y, bot.obstacleMap.getTile(b.x, b.y)))
    bot.obstacleMap.markTile(b.x, b.y, TileBlocked)
  defer:
    for s in saved:
      bot.obstacleMap.markTile(s.x, s.y, s.prev)
  if bot.stuckCount >= 15:
    let mask = unstickStep(bot.obstacleMap, bot.selfTileX, bot.selfTileY, bot.frameTick)
    bot.updateStuckState(mask)
    return mask
  let mask = pathStep(bot.obstacleMap, bot.selfTileX, bot.selfTileY, targetX, targetY)
  bot.updateStuckState(mask)
  mask

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

const
  RequiredElephant = 4  # elephant needs all 4 cardinal sides
  LowEnergyThreshold = 32  # retreat threshold — survives 1 trample + 1 move
  RechargedThreshold = 64  # rejoin hunting (2 tramples of buffer)
  SafeDistance = 5  # chebyshev tiles from any elephant during retreat
  CommitDistance = 2  # already in striking range — don't bail

proc chooseElephant(
  selfX, selfY: int,
  prey: openArray[PreySight],
  players: openArray[PlayerSight],
  selfObjectId: int
): PreySight =
  ## Elephants need ALL FOUR sides — if hunters split between two
  ## elephants neither gets captured. So this picks the elephant whose
  ## *farthest* visible hunter is closest. With identical visibility,
  ## every hunter computes the same "worst-case hunter distance" and
  ## they all converge on the same target. Cooperation bonus pulls in
  ## when hunters are already adjacent.
  var bestCost = high(int)
  for p in prey:
    if p.kind != Elephant:
      continue
    var maxHunterDist = chebyshev(selfX, selfY, p.tileX, p.tileY)
    var alliesAdjacent = 0
    for pl in players:
      if pl.objectId == selfObjectId: continue
      let d = chebyshev(pl.tileX, pl.tileY, p.tileX, p.tileY)
      if d > maxHunterDist: maxHunterDist = d
      if d == 1: inc alliesAdjacent
    if alliesAdjacent >= RequiredElephant:
      continue
    let
      cooperationBonus = -3 * alliesAdjacent
      cost = maxHunterDist + cooperationBonus
    if cost < bestCost or
        (cost == bestCost and result.found and p.objectId < result.objectId):
      bestCost = cost
      result = p

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

proc rankAmongVisible(
  selfObjectId: int, players: openArray[PlayerSight]
): int =
  ## Number of other visible hunters with a smaller objectId. Used as a
  ## stable side/corner assignment so several hunters with the same
  ## view land on different sides without coordination.
  result = 0
  for pl in players:
    if pl.objectId == selfObjectId: continue
    if pl.objectId < selfObjectId: inc result

proc sideAndCornerForRank(
  rank, preyX, preyY: int
): tuple[sideX, sideY, cornerX, cornerY: int] =
  ## rank 0 -> N side & NE corner
  ## rank 1 -> E side & SE corner
  ## rank 2 -> S side & SW corner
  ## rank 3 -> W side & NW corner
  case rank mod 4
  of 0: (preyX,     preyY - 1, preyX + 1, preyY - 1)
  of 1: (preyX + 1, preyY,     preyX + 1, preyY + 1)
  of 2: (preyX,     preyY + 1, preyX - 1, preyY + 1)
  else: (preyX - 1, preyY,     preyX - 1, preyY - 1)

proc bestElephantSide(
  selfX, selfY, preyX, preyY: int,
  selfObjectId: int,
  players: openArray[PlayerSight],
  obstacleMap: ObstacleMap
): tuple[x, y: int, found: bool] =
  ## Assign side by rank among visible hunters (sorted by objectId): rank
  ## 0 prefers N, rank 1 E, rank 2 S, rank 3 W. Skip sides that are
  ## occupied by another player *or blocked by a tree/rock*; without the
  ## obstacle check, a hunter assigned to a wall-blocked side will hover
  ## next to the elephant forever instead of falling through to an open
  ## side.
  let sides = occupiedSidesOf(preyX, preyY, players)
  var rank = 0
  for pl in players:
    if pl.objectId == selfObjectId: continue
    if pl.objectId < selfObjectId: inc rank
  let primary = rank mod 4
  const offsets = [(0, -1), (1, 0), (0, 1), (-1, 0)]
  for offset in 0 ..< 4:
    let ord = (primary + offset) mod 4
    if sideOccupied(sides, ord): continue
    let
      sx = preyX + offsets[ord][0]
      sy = preyY + offsets[ord][1]
    if not inBounds(sx, sy): continue
    if obstacleMap.getTile(sx, sy) == TileBlocked: continue
    return (sx, sy, true)
  (0, 0, false)

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

proc decideMask(bot: var Bot): uint8 =
  bot.updateCamera()
  if not bot.cameraKnown: return 0
  let players = bot.visiblePlayers()
  bot.identifySelf(players)
  if not bot.haveSelf: return 0
  bot.updateObstacleMap()

  # Priority 1: step into a kill spot (1-dot indicator nearby)
  let killSpot = bot.findKillSpot()
  if killSpot.found:
    if bot.selfTileX == killSpot.x and bot.selfTileY == killSpot.y:
      bot.updateStuckState(0)
      return 0
    return bot.navigate(killSpot.x, killSpot.y)

  let prey = bot.visiblePrey()

  # Energy gating with hysteresis. Once we drop below LowEnergyThreshold
  # we set rechargingUntil = 1 (a sentinel "still recharging" marker) and
  # stay in retreat until energy climbs to RechargedThreshold. Without
  # the gate, bots wade into elephants at energy 30, get trampled to 0,
  # and spend the rest of the round shuffling 1 tile per second.
  if bot.energyKnown:
    if bot.energy < LowEnergyThreshold:
      bot.rechargingUntil = 1
    elif bot.energy >= RechargedThreshold:
      bot.rechargingUntil = 0
  var lowEnergy = bot.energyKnown and bot.rechargingUntil != 0

  # Don't bail mid-hunt: if we're already in striking range AND there are
  # other hunters next to us, the capture is moments away. Eating one
  # trample now and retreating after the kill is better than scattering
  # and giving the elephant another loop to chew through everyone.
  if lowEnergy:
    var nearestElephantD = high(int)
    for p in prey:
      if p.kind != Elephant: continue
      let d = chebyshev(bot.selfTileX, bot.selfTileY, p.tileX, p.tileY)
      if d < nearestElephantD: nearestElephantD = d
    if nearestElephantD <= CommitDistance:
      var alliesClose = 0
      for pl in players:
        if pl.objectId == bot.selfObjectId: continue
        if chebyshev(pl.tileX, pl.tileY, bot.selfTileX, bot.selfTileY) <= 3:
          inc alliesClose
      if alliesClose >= 2:
        lowEnergy = false

  if lowEnergy:
    # Retreat: find the farthest direction from any visible elephant and
    # step there, or hold still if already safe. Allies' positions count
    # as blocked so we don't bunch up on one safe tile.
    var blocked: seq[tuple[x, y: int]] = @[]
    for pl in players:
      if pl.objectId != bot.selfObjectId:
        blocked.add((pl.tileX, pl.tileY))
    var nearestElephantDist = high(int)
    var ex, ey = 0
    for p in prey:
      if p.kind != Elephant: continue
      let d = chebyshev(bot.selfTileX, bot.selfTileY, p.tileX, p.tileY)
      if d < nearestElephantDist:
        nearestElephantDist = d; ex = p.tileX; ey = p.tileY
    if nearestElephantDist >= SafeDistance:
      bot.updateStuckState(0)
      return 0
    # Move directly away from the elephant. Pick the in-bounds, non-
    # blocked neighbor that maximizes distance to the elephant.
    var bestDist = nearestElephantDist
    var bestTx = bot.selfTileX
    var bestTy = bot.selfTileY
    const dirs = [(0, -1), (1, 0), (0, 1), (-1, 0)]
    for d in dirs:
      let nx = bot.selfTileX + d[0]
      let ny = bot.selfTileY + d[1]
      if not inBounds(nx, ny): continue
      if bot.obstacleMap.getTile(nx, ny) == TileBlocked: continue
      var occupied = false
      for b in blocked:
        if b.x == nx and b.y == ny: occupied = true; break
      if occupied: continue
      let dd = chebyshev(nx, ny, ex, ey)
      if dd > bestDist:
        bestDist = dd; bestTx = nx; bestTy = ny
    if bestTx == bot.selfTileX and bestTy == bot.selfTileY:
      bot.updateStuckState(0)
      return 0
    return bot.navigateAvoiding(bestTx, bestTy, blocked)

  let elephant = chooseElephant(bot.selfTileX, bot.selfTileY, prey, players, bot.selfObjectId)

  # Hunt strategy:
  # 1. Each hunter has a rank-based assignment to one of N/E/S/W sides
  #    (plus the corresponding diagonal corner one step further out).
  # 2. The hunter heads to its CORNER first (chebyshev 2). That tile
  #    can't be reached by a cardinal-only elephant on its next move,
  #    so it's safe to wait there without bleeding energy.
  # 3. Once 4 hunters are pre-positioned around an elephant (anyone
  #    within chebyshev 2), every hunter commits — steps to their side
  #    on the same tick. The elephant has all four sides simultaneously
  #    occupied and is captured before it can move.
  # 4. If our energy is low and we're not part of an imminent capture,
  #    hold position to recharge instead of feeding the elephant more
  #    free trample damage.
  if elephant.found:
    bot.mode = ModeHunt
    bot.adjacentWaitTicks = 0
    bot.lastAdjacentPreyId = -1
    let
      rank = rankAmongVisible(bot.selfObjectId, players)
      assignment = sideAndCornerForRank(rank, elephant.tileX, elephant.tileY)
      myDist = chebyshev(bot.selfTileX, bot.selfTileY,
                          elephant.tileX, elephant.tileY)
    var alliesInPosition = 0
    for pl in players:
      if pl.objectId == bot.selfObjectId: continue
      let d = chebyshev(pl.tileX, pl.tileY,
                         elephant.tileX, elephant.tileY)
      if d <= 2: inc alliesInPosition
    let groupReady = alliesInPosition >= 3 and myDist <= 2

    var blocked: seq[tuple[x, y: int]] = @[]
    for pl in players:
      if pl.objectId != bot.selfObjectId:
        blocked.add((pl.tileX, pl.tileY))

    if groupReady:
      # Commit — step to our cardinal side. If that exact side is
      # already taken by another hunter (e.g. ranks collided when
      # someone's out of view), fall back to bestElephantSide.
      var target = (x: assignment.sideX, y: assignment.sideY)
      var taken = false
      for pl in players:
        if pl.tileX == target.x and pl.tileY == target.y:
          taken = true; break
      if taken:
        let alt = bestElephantSide(
          bot.selfTileX, bot.selfTileY, elephant.tileX, elephant.tileY,
          bot.selfObjectId, players, bot.obstacleMap
        )
        if alt.found: target = (x: alt.x, y: alt.y)
      if bot.selfTileX == target.x and bot.selfTileY == target.y:
        bot.updateStuckState(0)
        return 0
      return bot.navigateAvoiding(target.x, target.y, blocked)

    # Not yet ready — head to our corner. The corner is at chebyshev 2
    # diagonal; an elephant can't step onto a diagonal in one move, so
    # we don't soak trample damage while waiting. While navigating
    # *to* the corner, mark the four cardinal-adjacent tiles around the
    # elephant as blocked too — otherwise the BFS happily routes
    # through one and the elephant tramples us in transit.
    let
      cornerX = assignment.cornerX
      cornerY = assignment.cornerY
    if bot.selfTileX == cornerX and bot.selfTileY == cornerY:
      bot.updateStuckState(0)
      return 0
    var transitBlocked = blocked
    transitBlocked.add((elephant.tileX, elephant.tileY - 1))  # N
    transitBlocked.add((elephant.tileX + 1, elephant.tileY))  # E
    transitBlocked.add((elephant.tileX, elephant.tileY + 1))  # S
    transitBlocked.add((elephant.tileX - 1, elephant.tileY))  # W
    return bot.navigateAvoiding(cornerX, cornerY, transitBlocked)

  # No elephant visible. A lone or partially-joined elephant_hunter
  # cannot capture anything (needs 4), so explore doubles as "stay close
  # enough to three allies that a freshly-spawned elephant can be jumped
  # by four of us."
  bot.mode = ModeExplore
  bot.adjacentWaitTicks = 0
  bot.lastAdjacentPreyId = -1

  # If we can see an ally that's more than 3 tiles away, close the gap.
  # Distance 3 leaves room for four to converge on an elephant without
  # piling on the same tile.
  # Route around visible allies during exploration too — without this,
  # several bots heading for the same quadrant collide and oscillate on
  # adjacent tiles instead of moseying.
  var blocked: seq[tuple[x, y: int]] = @[]
  for pl in players:
    if pl.objectId != bot.selfObjectId:
      blocked.add((pl.tileX, pl.tileY))

  var nearestAlly: PlayerSight
  var nearestAllyDist = high(int)
  for pl in players:
    if pl.objectId == bot.selfObjectId: continue
    let d = chebyshev(bot.selfTileX, bot.selfTileY, pl.tileX, pl.tileY)
    if d < nearestAllyDist:
      nearestAllyDist = d
      nearestAlly = pl
  if nearestAlly.found and nearestAllyDist > 3:
    return bot.navigateAvoiding(nearestAlly.tileX, nearestAlly.tileY, blocked)

  inc bot.exploreTargetAge
  let atTarget = (bot.selfTileX == bot.exploreTargetX and
                  bot.selfTileY == bot.exploreTargetY)
  if atTarget or bot.exploreTargetAge > 200 or bot.stuckCount > 30:
    bot.pickExploreTarget()

  bot.navigateAvoiding(bot.exploreTargetX, bot.exploreTargetY, blocked)

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
  name = "elephant_hunter",
  token = "",
  slot = -1
) =
  let endpoint = connectUrl(address, url, name, token, port, slot)
  while true:
    try:
      echo "elephant_hunter connecting to ", endpoint
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
      echo "elephant_hunter reconnecting after error: ", e.msg
      sleep(ConnectRetryDelayMs)

when isMainModule:
  randomize()
  var
    address = DefaultHost
    port = DefaultPort
    url = getEnv("COGAMES_ENGINE_WS_URL")
    name = "elephant_hunter"
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
