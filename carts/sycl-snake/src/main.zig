//! @author_name    Cameron Knight
//! @author_handle  CamoKnight117
//! @cart_title     sycl-snake
//! @description    A snake game made for the SYCL Vancouver 2026 badge

const std = @import("std");
const cart = @import("cart-api");
comptime {
    cart.export_start_code();
}

/// Custom panic handler: sends the message via cart.trace() then halts
/// without @breakpoint() (which causes a silent HardFault and system reset).
/// The [CART] prefix lets you spot it immediately in the USB console.
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    cart.trace(msg);
    // Loop without triggering a HardFault so Core 0 has time to print the
    // trace message before the cart freezes.
    // Use a low-power wait on ARM, plain spin on other targets (e.g. WASM).
    while (true) {
        if (!cart.is_simulator) {
            asm volatile ("wfe");
        }
    }
}

const black = defColor(0x000000);
const white = defColor(0xffffff);
const grey = defColor(0x777777);
const red = defColor(0xf82828);
//const dred = defColor(0x3e0000);
const green = defColor(0x00ff00);
const dgreen = defColor(0x003c00);
const blue = defColor(0x7777ff);
//const purp = defColor(0x820eef);

//fn borrowed from space-shooter cart
inline fn defColor(rgb: u24) cart.NeopixelColor {
    return .{
        .r = @intCast((rgb >> 16) & 0xff),
        .g = @intCast((rgb >> 8) & 0xff),
        .b = @intCast(rgb & 0xff),
    };
}

//fn borrowed from space-shooter cart
inline fn blend(from: cart.NeopixelColor, to: cart.NeopixelColor, f: f32) cart.NeopixelColor {
    const clamped = @min(1.0, @max(0.0, f));
    return .{
        .r = @intFromFloat((from.r * (1.0 - clamped)) + (to.r * clamped)),
        .g = @intFromFloat((from.g * (1.0 - clamped)) + (to.g * clamped)),
        .b = @intFromFloat((from.b * (1.0 - clamped)) + (to.b * clamped)),
    };
}

//fn borrowed from space-shooter cart
inline fn rgb565(clr: cart.NeopixelColor) cart.DisplayColor {
    return .{
        .r = @intCast(clr.r / 8),
        .g = @intCast(clr.g / 4),
        .b = @intCast(clr.b / 8),
    };
}

// rand implementation "borrowed" from the blobs cart
var rand: std.Random.DefaultPrng = undefined;
fn rand_float() f32 {
    const byte_count = 2;
    const UInt = @Int(.unsigned, byte_count * 8);
    var buf: [byte_count]u8 = undefined;
    rand.fill(&buf);
    const r = std.mem.readInt(UInt, &buf, .big);
    return @as(f32, @floatFromInt(r)) / (@as(f32, 1.0) + @as(f32, std.math.maxInt(UInt)));
}

const Coordinate = struct {
    x: u8,
    y: u8,
};

const Direction = enum {
    up,
    down,
    left,
    right,
};

const Vector = struct {
    origin: Coordinate,
    direction: Direction,
};

const Snake = struct {
    head_coord: Coordinate,
    tail_coord: Coordinate,
    body_len: u8,
    color_1: cart.NeopixelColor,
    color_2: cart.NeopixelColor,
    color_eyes: cart.NeopixelColor,
    current_direction: Direction,
    score: u16,
};

const Pip = struct {
    color_1: cart.NeopixelColor = white,
    color_2: cart.NeopixelColor = white,
    size: u8 = 3,
};

const Wall = struct {
    color_1: cart.NeopixelColor = white,
    color_2: cart.NeopixelColor = grey,
    //Other types necessary for walls? Thickness? Sprite?
};

const MovementResult = enum {
    collision,
    collected_pip,
    normal,
    err,
};

const MapLocationType = enum {
    empty,
    wall,
    snake_head,
    snake_body_up,
    snake_body_down,
    snake_body_left,
    snake_body_right,
    pip,
};

const map_width: u32 = 32; //map width in grid squares
const map_height: u32 = 25; //map height in grid squares
const map_size = map_width * map_height; //total grid squares
const gridsquare_width: u32 = 5; //pixel width of grid squares
// const start_pips = 2;
// const max_pips = 10;
var snake_1: Snake = undefined;

// var snake_2: Snake = undefined;
// var pips: [max_pips]Pip = undefined;
var map_grid: [map_width][map_height]MapLocationType = undefined;
var wall: Wall = undefined;
var pip: Pip = undefined;

var mixer: cart.mixer.Mixer(.{}) = .{};

pub fn start() void {
    rand = std.Random.DefaultPrng.init(5831);

    map_grid = std.mem.zeroes([map_width][map_height]MapLocationType);
    addWallsToMap();
    addStartingPipsToMap();

    snake_1 = .{
        .head_coord = .{ .x = 16, .y = 12 },
        .tail_coord = .{ .x = 16, .y = 14 },
        .body_len = 3,
        .color_1 = green,
        .color_2 = dgreen,
        .color_eyes = red,
        .current_direction = .up,
        .score = 0,
    };
    addSnakeToMap();

    wall = .{};
    pip = .{};

    // Enable vsync but tune the framerate to be as fast as possible for the app timing
    cart.set_vsync_dynamic();

    // Use the OS to clear every frame to black before it gets to the cart
    cart.set_double_buffer_mode(.{ .clear_full_frame = rgb565(black) });

    mixer.start_audio();
}

fn addWallsToMap() void {
    for (0..map_width) |x| {
        map_grid[x][0] = MapLocationType.wall;
        map_grid[x][map_height - 1] = MapLocationType.wall;
    }
    for (0..map_height) |y| {
        map_grid[0][y] = MapLocationType.wall;
        map_grid[map_width - 1][y] = MapLocationType.wall;
    }
}

fn addStartingPipsToMap() void {
    map_grid[4][17] = MapLocationType.pip;
    map_grid[19][7] = MapLocationType.pip;
    map_grid[22][20] = MapLocationType.pip;
}

fn addSnakeToMap() void {
    switch (snake_1.current_direction) {
        .up => {
            for (0..snake_1.body_len) |index| {
                if (index == 0)
                    map_grid[snake_1.head_coord.x][snake_1.head_coord.y + index] = MapLocationType.snake_head;
                if (index != 0)
                    map_grid[snake_1.head_coord.x][snake_1.head_coord.y + index] = MapLocationType.snake_body_up;
            }
            snake_1.tail_coord.x = snake_1.head_coord.x;
            snake_1.tail_coord.y = snake_1.head_coord.y + snake_1.body_len - 1;
        },
        .down => {
            for (0..snake_1.body_len) |index| {
                if (index == 0)
                    map_grid[snake_1.head_coord.x][snake_1.head_coord.y - index] = MapLocationType.snake_head;
                if (index != 0)
                    map_grid[snake_1.head_coord.x][snake_1.head_coord.y - index] = MapLocationType.snake_body_down;
            }
            snake_1.tail_coord.x = snake_1.head_coord.x;
            snake_1.tail_coord.y = snake_1.head_coord.y - snake_1.body_len + 1;
        },
        .left => {
            for (0..snake_1.body_len) |index| {
                if (index == 0)
                    map_grid[snake_1.head_coord.x + index][snake_1.head_coord.y] = MapLocationType.snake_head;
                if (index != 0)
                    map_grid[snake_1.head_coord.x + index][snake_1.head_coord.y] = MapLocationType.snake_body_left;
            }
            snake_1.tail_coord.x = snake_1.head_coord.x + snake_1.body_len - 1;
            snake_1.tail_coord.y = snake_1.head_coord.y + snake_1.body_len;
        },
        .right => {
            for (0..snake_1.body_len) |index| {
                if (index == 0)
                    map_grid[snake_1.head_coord.x - index][snake_1.head_coord.y] = MapLocationType.snake_head;
                if (index != 0)
                    map_grid[snake_1.head_coord.x - index][snake_1.head_coord.y] = MapLocationType.snake_body_right;
            }
            snake_1.tail_coord.x = snake_1.head_coord.x - snake_1.body_len + 1;
            snake_1.tail_coord.y = snake_1.head_coord.y + snake_1.body_len;
        },
    }
}

var movementTick: u8 = 0;
var movementTickMax: u8 = 20;
fn tickSnake() void {
    if (cart.controls.up) {
        snake_1.current_direction = .up;
    }
    if (cart.controls.down) {
        snake_1.current_direction = .down;
    }
    if (cart.controls.left) {
        snake_1.current_direction = .left;
    }
    if (cart.controls.right) {
        snake_1.current_direction = .right;
    }
    movementTick += (snake_1.body_len / 10) + 1;

    if (movementTick > movementTickMax) {
        movementTick = 0;
        const moveResult = MoveSnake(snake_1.current_direction);
        switch (moveResult) {
            .collision => {
                gameState = GameState.game_over;
            },
            .collected_pip => {},
            .normal => {},
            .err => {},
        }
    }
}

var prng = std.Random.DefaultPrng.init(6428);
const newRand = prng.random();
fn spawnPip() void {
    var spawned: bool = false;
    while (!spawned) {
        const randX = newRand.intRangeAtMost(u8, 1, map_width - 1);
        const randY = newRand.intRangeAtMost(u8, 1, map_height - 1);
        const locationType: MapLocationType = map_grid[randX][randY];
        if (locationType == MapLocationType.empty) {
            map_grid[randX][randY] = MapLocationType.pip;
            spawned = true;
        }
    }
}

var pipTick: u16 = 0;
var pipMax: u8 = 200;
fn tickPips() void {
    pipTick += 1;
    if (pipTick > pipMax) {
        pipTick = 0;
        spawnPip();
    }
}

fn drawSnakeSegment(x: i32, y: i32) void {
    cart.rect(.{
        .x = x * gridsquare_width,
        .y = y * gridsquare_width,
        .width = gridsquare_width,
        .height = gridsquare_width,
        .stroke_color = rgb565(snake_1.color_2),
        .fill_color = rgb565(snake_1.color_1),
    });
}

fn drawSnakeHead(x: i32, y: i32) void {
    drawSnakeSegment(x, y);
    switch (snake_1.current_direction) {
        .up => {
            cart.rect(.{
                .x = x * gridsquare_width + 1,
                .y = y * gridsquare_width + 1,
                .width = 1,
                .height = 1,
                .stroke_color = rgb565(snake_1.color_eyes),
                .fill_color = rgb565(snake_1.color_eyes),
            });
            cart.rect(.{
                .x = x * gridsquare_width + gridsquare_width - 2,
                .y = y * gridsquare_width + 1,
                .width = 1,
                .height = 1,
                .stroke_color = rgb565(snake_1.color_eyes),
                .fill_color = rgb565(snake_1.color_eyes),
            });
        },
        .down => {
            cart.rect(.{
                .x = x * gridsquare_width + gridsquare_width - 2,
                .y = y * gridsquare_width + gridsquare_width - 2,
                .width = 1,
                .height = 1,
                .stroke_color = rgb565(snake_1.color_eyes),
                .fill_color = rgb565(snake_1.color_eyes),
            });
            cart.rect(.{
                .x = x * gridsquare_width + 1,
                .y = y * gridsquare_width + gridsquare_width - 2,
                .width = 1,
                .height = 1,
                .stroke_color = rgb565(snake_1.color_eyes),
                .fill_color = rgb565(snake_1.color_eyes),
            });
        },
        .left => {
            cart.rect(.{
                .x = x * gridsquare_width + 1,
                .y = y * gridsquare_width + gridsquare_width - 2,
                .width = 1,
                .height = 1,
                .stroke_color = rgb565(snake_1.color_eyes),
                .fill_color = rgb565(snake_1.color_eyes),
            });
            cart.rect(.{
                .x = x * gridsquare_width + 1,
                .y = y * gridsquare_width + 1,
                .width = 1,
                .height = 1,
                .stroke_color = rgb565(snake_1.color_eyes),
                .fill_color = rgb565(snake_1.color_eyes),
            });
        },
        .right => {
            cart.rect(.{
                .x = x * gridsquare_width + gridsquare_width - 2,
                .y = y * gridsquare_width + 1,
                .width = 1,
                .height = 1,
                .stroke_color = rgb565(snake_1.color_eyes),
                .fill_color = rgb565(snake_1.color_eyes),
            });
            cart.rect(.{
                .x = x * gridsquare_width + gridsquare_width - 2,
                .y = y * gridsquare_width + gridsquare_width - 2,
                .width = 1,
                .height = 1,
                .stroke_color = rgb565(snake_1.color_eyes),
                .fill_color = rgb565(snake_1.color_eyes),
            });
        },
    }
}

fn MoveSnake(direction: Direction) MovementResult {
    //Check spot in front of snake
    //Replace the head with a direction body segment
    var spot_ahead_type: MapLocationType = undefined;
    var spot_ahead_coord: Coordinate = snake_1.head_coord;
    switch (direction) {
        .up => {
            spot_ahead_coord.y -= 1;
            map_grid[snake_1.head_coord.x][snake_1.head_coord.y] = MapLocationType.snake_body_up;
        },
        .down => {
            spot_ahead_coord.y += 1;
            map_grid[snake_1.head_coord.x][snake_1.head_coord.y] = MapLocationType.snake_body_down;
        },
        .left => {
            spot_ahead_coord.x -= 1;
            map_grid[snake_1.head_coord.x][snake_1.head_coord.y] = MapLocationType.snake_body_left;
        },
        .right => {
            spot_ahead_coord.x += 1;
            map_grid[snake_1.head_coord.x][snake_1.head_coord.y] = MapLocationType.snake_body_right;
        },
    }
    //Save what is in front of the snake
    spot_ahead_type = map_grid[spot_ahead_coord.x][spot_ahead_coord.y];
    var future_ret_val: MovementResult = MovementResult.normal;
    switch (spot_ahead_type) {
        .wall, .snake_body_down, .snake_body_left, .snake_body_right, .snake_body_up, .snake_head => {
            return MovementResult.collision;
        },
        .pip => {
            future_ret_val = .collected_pip;
            collectedPip();
        },
        .empty => {
            future_ret_val = .normal;
        },
    }

    if (future_ret_val != .collected_pip) {
        //Replace tail with empty grid
        const tail_type = map_grid[snake_1.tail_coord.x][snake_1.tail_coord.y];
        map_grid[snake_1.tail_coord.x][snake_1.tail_coord.y] = MapLocationType.empty;
        switch (tail_type) {
            .snake_body_up => {
                snake_1.tail_coord.y -= 1;
            },
            .snake_body_down => {
                snake_1.tail_coord.y += 1;
            },
            .snake_body_left => {
                snake_1.tail_coord.x -= 1;
            },
            .snake_body_right => {
                snake_1.tail_coord.x += 1;
            },
            .empty, .snake_head, .pip, .wall => {},
        }
    }

    //Add head to spot in front
    map_grid[spot_ahead_coord.x][spot_ahead_coord.y] = MapLocationType.snake_head;
    snake_1.head_coord.x = spot_ahead_coord.x;
    snake_1.head_coord.y = spot_ahead_coord.y;

    return future_ret_val;
}

fn collectedPip() void {
    snake_1.score += 1;
    snake_1.body_len += 1;
    spawnPip();
}

fn resetGame() void {
    snake_1.score = 0;
    map_grid = std.mem.zeroes([map_width][map_height]MapLocationType);
    addWallsToMap();
    addStartingPipsToMap();

    snake_1 = .{
        .head_coord = .{ .x = 16, .y = 12 },
        .tail_coord = .{ .x = 16, .y = 14 },
        .body_len = 3,
        .color_1 = green,
        .color_2 = dgreen,
        .color_eyes = red,
        .current_direction = .up,
        .score = 0,
    };
    addSnakeToMap();
}

fn drawUi() void {
    cart.trace("ss:draw-l");
    if (snake_1.score > 0) {
        var text: [32]u8 = undefined;
        const txt = std.fmt.bufPrintSentinel(&text, "{}", .{snake_1.score}, 0) catch "-";
        cart.text(.{
            .str = txt,
            .x = @intCast((cart.screen_width - cart.font_width * txt.len) / 2),
            .y = 10,
            .text_color = rgb565(grey),
        });
    }
}

fn drawUiGameEnd() void {
    cart.trace("ss:draw-l");
    if (snake_1.score > 0) {
        var text: [32]u8 = undefined;
        const txt = std.fmt.bufPrintSentinel(&text, "Score: {}", .{snake_1.score}, 0) catch "-";
        cart.text(.{
            .str = txt,
            .x = @intCast((cart.screen_width - cart.font_width * txt.len) / 2),
            .y = 80,
            .text_color = rgb565(grey),
        });
    }
}

fn drawMap() void {
    cart.trace("ss:draw-w");
    for (0..map_width) |x| {
        for (0..map_height) |y| {
            const currentLocation = map_grid[x][y];
            if (map_grid[x][y] == MapLocationType.wall) {
                drawWallSegment(@as(i32, @intCast(x)) * gridsquare_width, @as(i32, @intCast(y)) * gridsquare_width);
            }
            switch (currentLocation) {
                .wall => {
                    drawWallSegment(@as(i32, @intCast(x)) * gridsquare_width, @as(i32, @intCast(y)) * gridsquare_width);
                },
                .empty => {
                    drawEmptySquare(@as(i32, @intCast(x)), @as(i32, @intCast(y)));
                },
                .snake_body_down, .snake_body_left, .snake_body_right, .snake_body_up => {
                    drawSnakeSegment(@as(i32, @intCast(x)), @as(i32, @intCast(y)));
                },
                .snake_head => {
                    drawSnakeHead(@as(i32, @intCast(x)), @as(i32, @intCast(y)));
                },
                .pip => {
                    drawPip(@as(i32, @intCast(x)), @as(i32, @intCast(y)));
                },
            }
        }
    }
}

fn drawWallSegment(x: i32, y: i32) void {
    cart.rect(.{
        .x = x,
        .y = y,
        .width = gridsquare_width,
        .height = gridsquare_width,
        .stroke_color = rgb565(wall.color_1),
        .fill_color = rgb565(wall.color_2),
    });
}

fn drawEmptySquare(x: i32, y: i32) void {
    cart.rect(.{
        .x = x * gridsquare_width + gridsquare_width / 2,
        .y = y * gridsquare_width + gridsquare_width / 2,
        .width = 1,
        .height = 1,
        .stroke_color = rgb565(white),
        .fill_color = rgb565(white),
    });
}

fn drawPip(x: i32, y: i32) void {
    cart.rect(.{
        .x = x * gridsquare_width + gridsquare_width / 2 - 1,
        .y = y * gridsquare_width + gridsquare_width / 2 - 1,
        .width = pip.size,
        .height = pip.size,
        .stroke_color = rgb565(pip.color_2),
        .fill_color = rgb565(pip.color_1),
    });
}

const GameState = enum {
    intro,
    game,
    game_over,
};
var gameState: GameState = .intro;

const introText = &[_][]const u8{
    "SYCL",
    "SNAKE",
    "",
    "by @CamoKnight117",
    "",
    "Press START",
};
const spacing = (cart.font_height * 4 / 3);

fn drawIntroText() void {
    const y_start = (cart.screen_height - (cart.font_height + spacing * (introText.len - 1))) / 2;
    for (introText, 0..) |line, i| {
        cart.text(.{
            .str = line,
            .x = @as(i32, @intCast((cart.screen_width - cart.font_width * line.len) / 2)),
            .y = @as(i32, @intCast(y_start + spacing * i)),
            .text_color = rgb565(white),
        });
    }
}

const bannerText = "SYCL 2026";
const bannerWidth = cart.font_width * bannerText.len;
var bannerPos: f32 = cart.screen_width / 2;

fn drawBanner() void {
    cart.trace("ss:draw-bn");
    cart.text(.{
        .str = bannerText,
        .x = @intFromFloat(bannerPos),
        .y = cart.screen_height - 24,
        .text_color = rgb565(grey),
    });
    bannerPos -= 0.233;
    if (bannerPos < -@as(f32, @floatFromInt(bannerWidth)))
        bannerPos = cart.screen_width;
}

var stateTick: u16 = 0;
var pixelTick: u8 = 0;
var quietMode: bool = false;
var select_held_frames: u8 = 0; // Debounce: require SELECT held to reset from game

// // Diagnostic frame counter for crash-location tracing.
// // Every 30 frames we send "ss:F=NNN" via cart.trace() while in game mode.
// // draw_enemies() also sends a trace before each complex drawing operation
// // so the last [CART] message visible in the console before the crash/[PANIC]
// // pinpoints the crash location.
var diag_frame: u32 = 0;

pub fn update() void {
    if (stateTick > 1000) stateTick = 100;
    stateTick +%= 1;

    if (stateTick % 10 == 0) pixelTick += 1;
    if (pixelTick > 4) pixelTick = 0;

    if (cart.controls.select and cart.controls.up) {
        quietMode = false;
    }
    if (cart.controls.select and cart.controls.down) {
        quietMode = true;
    }

    if (gameState == .intro) {
        drawIntroText();

        if (stateTick > 10 and cart.controls.start) {
            gameState = .game;
            stateTick = 0;
        }

        for (cart.neopixels, 0..) |*np, i| {
            if (quietMode) {
                np.* = if (pixelTick == i) blue else black;
            } else {
                np.* = if (pixelTick == i) blend(black, white, 0.05) else black;
            }
        }
    } else if (gameState == .game_over) {
        const gameOver = "GAME OVER";
        if (rand_float() < 0.8) {
            cart.text(.{
                .str = gameOver,
                .x = (cart.screen_width - gameOver.len * cart.font_width) / 2,
                .y = (cart.screen_height - cart.font_height) / 2,
                .text_color = rgb565(red),
            });
        }
        if (stateTick > 10 and cart.controls.start) {
            resetGame();
            gameState = .intro;
            stateTick = 0;
        }
        for (cart.neopixels) |*np| {
            if (rand_float() > 0.8) {
                np.* = black;
            } else if (rand_float() > 0.8) {
                np.* = red;
            }
        }
        drawUiGameEnd();
    } else {
        // SELECT+DOWN = intentional reset (avoids accidental resets from SELECT noise).
        // SELECT alone no longer resets - was causing rapid resets to intro screen.
        if (stateTick > 60 and cart.controls.select and cart.controls.down) {
            select_held_frames +%= 1;
        } else {
            select_held_frames = 0;
        }
        if (select_held_frames >= 20) {
            resetGame();
            gameState = .intro;
            stateTick = 0;
            select_held_frames = 0;
        }

        // Periodic heartbeat every 30 frames (~0.5s at 60fps).
        // If the crash happens DURING tick_game(), the last [CART] message
        // will be "ss:tick".  If inside draw_enemies(), it will be "ss:draw-e",
        // "ss:live", "ss:live-oval", or "ss:dying-oval".
        diag_frame +%= 1;
        if (diag_frame % 30 == 0) {
            cart.trace("ss:tick");
        }

        tickGame();
        // if (gameOverConditionMet()) {
        //     gameState = .game_over;
        //     stateTick = 0;
        //     return;
        // }
        drawGame();
    }

    mixer.update();
}

fn tickGame() void {
    cart.trace("ss:tg-snake");
    tickSnake();
    tickPips();
}

fn drawGame() void {
    drawMap();
    drawBanner();
    drawUi();
}
