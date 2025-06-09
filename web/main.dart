import 'package:bullseye2d/bullseye2d.dart';
import 'dart:collection';
import 'package:web/web.dart';
import 'package:collection/collection.dart';
import 'package:vector_math/vector_math.dart';

const tileSize = Point(8, 8);
const mapSize = Point(8, 8);

// dart format off
enum TileID {
  ground, target, crate, wall, wallAlt, playerDown, playerLeft, playerRight, playerUp;
  static int playerStartFrame = TileID.playerDown.index;
}
// dart format on

enum EntityType { player, crate }

enum GameScene { title, game, levelCompleted, gameCompleted }

double lerp(double a, double b, double t) => a + (b - a) * t;
double screenX(int x) => (x * tileSize.x).toDouble();
double screenY(int y) => (y * tileSize.y).toDouble();

class GameState {
  final int playerX;
  final int playerY;
  final int playerDir;
  final List<Point<int>> cratePositions;

  GameState(this.playerX, this.playerY, this.playerDir, this.cratePositions);
}

class Entity {
  EntityType type;

  int x;
  int y;

  var render = Vector2.zero();
  var start = Vector2.zero();
  var target = Vector2.zero();

  Entity(this.type, this.x, this.y) {
    snapToGrid();
  }

  void updateRenderPositions(double progress) {
    render.x = lerp(start.x, target.x, progress);
    render.y = lerp(start.y, target.y, progress);
  }

  void setTargetPositions(int targetX, int targetY) {
    start.setFrom(render);
    target.x = screenX(targetX);
    target.y = screenY(targetY);
  }

  void snapToGrid() {
    render.x = screenX(x);
    render.y = screenY(y);
    start.setFrom(render);
    target.setFrom(render);
  }
}

class Soko64 extends App {
  static const animationDuration = 0.1;
  static const scaleFactor = 20.0;
  static const keyPressTreshold = 25;
  static const undoPressedTreshold = 50;
  static const dirVectors = [Point(0, 1), Point(-1, 0), Point(1, 0), Point(0, -1)];
  static const inputKeys = [
    [KeyCodes.Down, KeyCodes.S],
    [KeyCodes.Left, KeyCodes.A],
    [KeyCodes.Right, KeyCodes.D],
    [KeyCodes.Up, KeyCodes.W],
  ];

  late BitmapFont font;
  late Images logo;
  late Images sprites;
  late Images award;

  late Sound sfxStartGame;
  late Sound sfxLevelClear;
  late Sound sfxWalk;
  late Sound sfxPushCrate;

  late Entity player;
  late List<Entity> crates;

  final List<GameState> undoStates = [];
  final Queue<Point<int>> inputQueue = Queue<Point<int>>();
  final keyPressedTime = [0, 0, 0, 0, 0];
  final playfield = List.generate(mapSize.x, (_) => List.filled(mapSize.y, 0));

  GameScene? currentState;
  Entity? animatingCrate;

  bool isAnimating = false;
  double animationProgress = 0.0;
  int counter = 0;
  int level = 1;
  int playerDir = TileID.playerStartFrame;

  Soko64() : super(AppConfig(autoSuspend: false));

  void requestMove(int dx, int dy) => inputQueue.addLast(Point(dx, dy));
  Entity? crateAt(int x, int y) => crates.firstWhereOrNull((e) => e.x == x && e.y == y);
  bool isFieldBlocked(int x, int y) => isWall(x, y) || isCrateAt(x, y);
  bool isOutOfBounds(int x, int y) => (x < 0 || x >= mapSize.x || y < 0 || y >= mapSize.y);
  bool isWall(int x, int y) => isOutOfBounds(x, y) || (playfield[x][y] == TileID.wall.index);
  bool isCrateAt(int x, int y) => crateAt(x, y) != null;

  @override
  onCreate() async {
    var params = Uri.dataFromString(window.location.search).queryParameters;
    if (params.containsKey('level')) {
      level = int.tryParse(params['level'] ?? '') ?? 1;
      setState(GameScene.game);
    } else {
      setState(GameScene.title);
    }

    int retriggerDelay = 50;
    sfxStartGame = resources.loadSound("sfx/01_start_game.mp3", retriggerDelayInMs: retriggerDelay);
    sfxLevelClear = resources.loadSound("sfx/02_level_clear.mp3", retriggerDelayInMs: retriggerDelay);
    sfxWalk = resources.loadSound("sfx/03_walk.mp3", retriggerDelayInMs: retriggerDelay);
    sfxPushCrate = resources.loadSound("sfx/04_push_crate.mp3", retriggerDelayInMs: retriggerDelay);

    award = resources.loadImage("gfx/award.png", textureFlags: TextureFlags.none);
    font = resources.loadFont("fonts/TinyUnicode.ttf", 16 * scaleFactor, antiAlias: false);
    logo = resources.loadImage("gfx/logo.png", textureFlags: TextureFlags.none);
    sprites = resources.loadImage(
      "gfx/sprites.png",
      frameWidth: 8,
      frameHeight: 8,
      textureFlags: TextureFlags.none,
      pivotX: 0,
      pivotY: 0,
    );
  }

  @override
  onUpdate() {
    counter += 1;

    if (currentState == GameScene.title) {
      if (keyboard.keyHit(KeyCodes.X)) {
        audio.playMusic("music/space_cadet_training_montage.mp3", true);
        setState(GameScene.game);
      }
      return;
    } else if (currentState == GameScene.levelCompleted) {
      if (counter > 100) {
        level += 1;
        setState(GameScene.game);
      }
      return;
    } else if (currentState == GameScene.gameCompleted) {
      if (keyboard.keyHit(KeyCodes.X)) {
        setState(GameScene.title);
      }
      return;
    }

    if (keyboard.keyHit(KeyCodes.Escape)) {
      setState(GameScene.title);
      return;
    }

    updateKeyPressCounter([KeyCodes.Down, KeyCodes.S], 0);
    updateKeyPressCounter([KeyCodes.Left, KeyCodes.A], 1);
    updateKeyPressCounter([KeyCodes.Right, KeyCodes.D], 2);
    updateKeyPressCounter([KeyCodes.Up, KeyCodes.W], 3);
    updateKeyPressCounter([KeyCodes.U], 4);

    for (int i = 0; i < inputKeys.length; i++) {
      final keyHit = inputKeys[i].firstWhereOrNull((k) => keyboard.keyHit(k));
      if (keyHit != null || (!isAnimating && keyPressedTime[i] > keyPressTreshold)) {
        playerDir = TileID.playerStartFrame + i;
        requestMove(dirVectors[i].x, dirVectors[i].y);
        break;
      }
    }

    // Handle Undo key press
    if (keyboard.keyHit(KeyCodes.U)) {
      restoreState();
    } else if (keyPressedTime[4] > undoPressedTreshold) {
      keyPressedTime[4] = undoPressedTreshold - 3;
      restoreState();
    }

    if (keyboard.keyHit(KeyCodes.R)) {
      if (undoStates.isNotEmpty) {
        final start = undoStates[0];
        undoStates.clear();
        undoStates.add(start);
        restoreState();
      }
    }

    if (!isAnimating) {
      player.snapToGrid();
      animatingCrate?.snapToGrid();
      animatingCrate = null;
      processNextMove();
    }

    if (isAnimating) {
      animationProgress += (1.0 / App.instance.updateRate) / animationDuration;
      animationProgress = animationProgress.clamp(0.0, 1.0);

      player.updateRenderPositions(animationProgress);
      animatingCrate?.updateRenderPositions(animationProgress);

      if (animationProgress >= 1.0) {
        player.snapToGrid();
        isAnimating = false;
        animatingCrate?.snapToGrid();
        animatingCrate = null;

        if (isLevelCompleted()) {
          setState(GameScene.levelCompleted);
          audio.playSound(sfxLevelClear);
          return;
        }

        processNextMove();
      }
    }
  }

  @override
  onRender() {
    gfx.clear(0, 0, 0.5);
    gfx.pushMatrix();
    gfx.scale(scaleFactor, scaleFactor);

    if (currentState == GameScene.title) {
      renderScreen(logo, "PRESS X\nTO START");
    } else if (currentState == GameScene.gameCompleted) {
      renderScreen(award, "SUPERB\nPRESS X");
    } else if (currentState == GameScene.game || currentState == GameScene.levelCompleted) {
      renderPlayfield();
    }

    gfx.popMatrix();
  }

  Future<bool> initLevel() async {
    log("Load level", level);
    undoStates.clear();
    var result = await loadLevel(level);
    if (!result) {
      return false;
    }
    saveState();
    return true;
  }

  Future<bool> loadLevel(int level) async {
    var levelDef = await resources.loadString("levels/$level.txt");
    if (levelDef == "") {
      return false;
    }
    var levelData = levelDef.trim().split("\n").where((s) => s.isNotEmpty && !s.trim().startsWith(";")).toList();
    assert(levelData.length == mapSize.y, "Level $level has wrong count of rows");

    crates = [];

    for (var y = 0; y < mapSize.y; ++y) {
      assert(levelData[y].length == mapSize.x, "Level $level count of columns wrong in row $y");
      for (var x = 0; x < mapSize.x; ++x) {
        playfield[x][y] = TileID.ground.index;

        switch (levelData[y][x]) {
          case '#':
            playfield[x][y] = TileID.wall.index;
            break;

          case 'X':
            crates.add(Entity(EntityType.crate, x, y));
            break;

          case '@':
            player = Entity(EntityType.player, x, y);
            playerDir = TileID.playerStartFrame;
            break;

          case '.':
            playfield[x][y] = TileID.target.index;
            break;

          case ' ':
          default:
            playfield[x][y] = TileID.ground.index;
            break;
        }
      }
    }

    player.snapToGrid();

    return true;
  }

  void processNextMove() {
    if (inputQueue.isEmpty || isAnimating) {
      return;
    }

    Point<int> move = inputQueue.removeFirst();
    int dx = move.x;
    int dy = move.y;

    int nextPlayerX = player.x + dx;
    int nextPlayerY = player.y + dy;

    if (isWall(nextPlayerX, nextPlayerY)) {
      return;
    }

    Entity? targetCrate = crateAt(nextPlayerX, nextPlayerY);

    bool willPushCrate = false;
    if (targetCrate != null) {
      int nextCrateX = nextPlayerX + dx;
      int nextCrateY = nextPlayerY + dy;

      if (isFieldBlocked(nextCrateX, nextCrateY)) {
        return;
      }

      willPushCrate = true;
    }

    saveState();

    player.setTargetPositions(nextPlayerX, nextPlayerY);

    if (willPushCrate) {
      animatingCrate = targetCrate;
      animatingCrate?.setTargetPositions(nextPlayerX + dx, nextPlayerY + dy);
      animatingCrate?.x = nextPlayerX + dx;
      animatingCrate?.y = nextPlayerY + dy;
      audio.playSound(sfxPushCrate);
    } else {
      audio.playSound(sfxWalk);
    }

    player.x = nextPlayerX;
    player.y = nextPlayerY;

    isAnimating = true;
    animationProgress = 0.0;
  }

  bool isLevelCompleted() {
    for (var y = 0; y < mapSize.y; ++y) {
      for (var x = 0; x < mapSize.x; x++) {
        if (playfield[x][y] == TileID.target.index) {
          if (!isCrateAt(x, y)) {
            return false;
          }
        }
      }
    }
    return true;
  }

  setState(GameScene nextState) async {
    if (nextState == currentState) {
      return;
    }

    counter = 0;

    switch (nextState) {
      case GameScene.title:
        var params = Uri.dataFromString(window.location.search).queryParameters;
        level = int.tryParse(params['level'] ?? '') ?? 1;
        audio.playMusic("music/face_the_facts.mp3", true);
        break;

      case GameScene.game:
        var result = await initLevel();
        if (!result) {
          setState(GameScene.gameCompleted);
          return;
        }
        break;

      case GameScene.levelCompleted:
        break;

      case GameScene.gameCompleted:
        break;
    }

    currentState = nextState;
  }

  void updateKeyPressCounter(List<KeyCodes> keys, int index) {
    if (keys.firstWhereOrNull((k) => keyboard.keyDown(k)) != null) {
      keyPressedTime[index] += 1;
    } else {
      keyPressedTime[index] = 0;
    }
  }

  void renderPlayfield() {
    for (var y = 0; y < mapSize.y; ++y) {
      for (var x = 0; x < mapSize.x; ++x) {
        var sx = screenX(x);
        var sy = screenY(y);

        gfx.drawImage(sprites, TileID.ground.index, sx, sy);

        if (playfield[x][y] == TileID.target.index) {
          gfx.drawImage(sprites, TileID.target.index, sx, sy);
        } else if (playfield[x][y] == TileID.wall.index) {
          bool renderAltWallTile = ((y + x) % 2) == 0;
          gfx.drawImage(sprites, (renderAltWallTile ? TileID.wall : TileID.wallAlt).index, screenX(x), screenY(y));
        }
      }
    }

    for (var crate in crates) {
      gfx.drawImage(sprites, TileID.crate.index, crate.render.x, crate.render.y);
    }

    gfx.drawImage(sprites, playerDir, player.render.x, player.render.y);
  }

  void renderScreen(Images image, String text) {
    double offsetY = sin(counter / 15) * 2.0;
    gfx.drawImage(image, 0, 32, 26 + offsetY);
    gfx.popMatrix();
    font.leadingMod = 0.5;
    if (((counter ~/ 20) % 4) < 3) {
      gfx.drawText(font, text, x: 32 * scaleFactor, y: 58 * scaleFactor, alignX: 0.5, alignY: 1.0);
    }
    gfx.pushMatrix();
  }

  void saveState() {
    final List<Point<int>> currentCratePositions = crates.map((c) => Point(c.x, c.y)).toList();
    undoStates.add(GameState(player.x, player.y, playerDir, currentCratePositions));
  }

  void restoreState() {
    if (undoStates.isEmpty) {
      return;
    }
    final state = undoStates.removeLast();

    player.x = state.playerX;
    player.y = state.playerY;
    playerDir = state.playerDir;

    crates.clear();
    for (var pos in state.cratePositions) {
      crates.add(Entity(EntityType.crate, pos.x, pos.y));
    }

    isAnimating = false;
    animationProgress = 0.0;
    player.snapToGrid();
    animatingCrate?.snapToGrid();
    animatingCrate = null;

    inputQueue.clear();
  }
}

main() {
  Soko64();
}
