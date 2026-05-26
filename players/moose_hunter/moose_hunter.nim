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
    resting: bool

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
  ## See elephant_hunter for rationale. Marks `blocked` tiles as
  ## impassable for this BFS only.
  var saved: seq[tuple[x, y: int, prev: TileStatus]] = @[]
  for b in blocked:
    if not inBounds(b.x, b.y): continue
    if b.x == targetX and b.y == targetY: continue
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

const RequiredMoose = 3  # moose needs 3 cardinal sides occupied

proc chooseMoose(
  selfX, selfY: int,
  prey: openArray[PreySight],
  players: openArray[PlayerSight],
  selfObjectId: int
): PreySight =
  ## Pick the moose whose farthest visible hunter is closest, so all
  ## hunters with the same view converge on the same one. Cooperation
  ## bonus pulls in when allies are already adjacent.
  var bestCost = high(int)
  for p in prey:
    if p.kind != Moose:
      continue
    var maxHunterDist = chebyshev(selfX, selfY, p.tileX, p.tileY)
    var alliesAdjacent = 0
    for pl in players:
      if pl.objectId == selfObjectId: continue
      let d = chebyshev(pl.tileX, pl.tileY, p.tileX, p.tileY)
      if d > maxHunterDist: maxHunterDist = d
      if d == 1: inc alliesAdjacent
    if alliesAdjacent >= RequiredMoose:
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

proc bestMooseSide(
  selfX, selfY, preyX, preyY: int,
  selfObjectId: int,
  players: openArray[PlayerSight],
  obstacleMap: ObstacleMap
): tuple[x, y: int, found: bool] =
  ## Assign side by rank among visible hunters (sorted by objectId): rank
  ## 0 prefers N first, rank 1 E, rank 2 S, rank 3 W, then cyclic. Skip
  ## sides occupied by another player *or blocked by an obstacle* —
  ## without the obstacle check, a hunter assigned to a tree-blocked side
  ## hovers next to the moose forever instead of falling through.
  let sides = occupiedSidesOf(preyX, preyY, players)
  var rank = 0
  for pl in players:
    if pl.objectId == selfObjectId: continue
    if pl.objectId < selfObjectId: inc rank
  let
    primary = rank mod 4
    dx = selfX - preyX
    dy = selfY - preyY
    approachPrim =
      if abs(dx) > abs(dy):
        (if dx > 0: 1 else: 3)
      elif abs(dy) > abs(dx):
        (if dy > 0: 2 else: 0)
      else:
        (if dx > 0: 1 else: 3)
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
  let
    sx = preyX + offsets[approachPrim][0]
    sy = preyY + offsets[approachPrim][1]
  (sx, sy, true)

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

  # Energy rest with moose-gut awareness. Moose can shove an adjacent
  # player (chebyshev 1) for -10 energy. Don't rest INSIDE that radius;
  # step one tile away first, then rest.
  if bot.energyKnown:
    if bot.energy < 30: bot.resting = true
    elif bot.energy >= 60: bot.resting = false
  if bot.resting:
    var nearestMooseDist = high(int)
    var mx, my = 0
    for p in prey:
      if p.kind != Moose: continue
      let d = max(abs(bot.selfTileX - p.tileX), abs(bot.selfTileY - p.tileY))
      if d < nearestMooseDist:
        nearestMooseDist = d; mx = p.tileX; my = p.tileY
    if nearestMooseDist <= 1:
      # Step the cardinal direction that maximizes distance from the moose.
      const dirs = [(0, -1), (1, 0), (0, 1), (-1, 0)]
      var bestDist = nearestMooseDist
      var bestTx = bot.selfTileX
      var bestTy = bot.selfTileY
      for d in dirs:
        let nx = bot.selfTileX + d[0]
        let ny = bot.selfTileY + d[1]
        if not inBounds(nx, ny): continue
        if bot.obstacleMap.getTile(nx, ny) == TileBlocked: continue
        let dd = max(abs(nx - mx), abs(ny - my))
        if dd > bestDist:
          bestDist = dd; bestTx = nx; bestTy = ny
      if bestTx != bot.selfTileX or bestTy != bot.selfTileY:
        return bot.navigate(bestTx, bestTy)
    bot.updateStuckState(0)
    return 0

  # If we're already adjacent to any moose, hold there — don't get
  # distracted by chooseMoose picking a different one (which would make
  # us abandon a partial encirclement).
  for p in prey:
    if p.kind != Moose: continue
    let
      adx = abs(bot.selfTileX - p.tileX)
      ady = abs(bot.selfTileY - p.tileY)
    if (adx == 1 and ady == 0) or (adx == 0 and ady == 1):
      bot.mode = ModeHunt
      if bot.lastAdjacentPreyId == p.objectId:
        inc bot.adjacentWaitTicks
      else:
        bot.lastAdjacentPreyId = p.objectId
        bot.adjacentWaitTicks = 1
      bot.updateStuckState(0)
      return 0

  let moose = chooseMoose(bot.selfTileX, bot.selfTileY, prey, players, bot.selfObjectId)

  # Hunt mode: moose visible — claim an unoccupied side and wait for 2
  # more hunters. Capture lands when any 3 cardinal sides are occupied.
  if moose.found:
    bot.mode = ModeHunt
    bot.adjacentWaitTicks = 0
    bot.lastAdjacentPreyId = -1

    let side = bestMooseSide(
      bot.selfTileX, bot.selfTileY, moose.tileX, moose.tileY,
      bot.selfObjectId, players, bot.obstacleMap
    )
    var blocked: seq[tuple[x, y: int]] = @[]
    for pl in players:
      if pl.objectId != bot.selfObjectId:
        blocked.add((pl.tileX, pl.tileY))
    if side.found:
      return bot.navigateAvoiding(side.x, side.y, blocked)
    return bot.navigateAvoiding(moose.tileX, moose.tileY, blocked)

  # No moose visible. A lone or paired moose_hunter cannot capture
  # anything (needs 3), so explore doubles as "stay close enough to two
  # allies that a freshly-spawned moose can be jumped by three of us."
  bot.mode = ModeExplore
  bot.adjacentWaitTicks = 0
  bot.lastAdjacentPreyId = -1

  # Route around visible allies during exploration — without this, two
  # bots heading to the same quadrant target collide and oscillate.
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
  name = "moose_hunter",
  token = "",
  slot = -1
) =
  let endpoint = connectUrl(address, url, name, token, port, slot)
  while true:
    try:
      echo "moose_hunter connecting to ", endpoint
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
      echo "moose_hunter reconnecting after error: ", e.msg
      sleep(ConnectRetryDelayMs)

when isMainModule:
  randomize()
  var
    address = DefaultHost
    port = DefaultPort
    url = getEnv("COGAMES_ENGINE_WS_URL")
    name = "moose_hunter"
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
