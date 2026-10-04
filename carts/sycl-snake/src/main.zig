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
    body_len: u8,
    body_locations: [map_size]Vector, //map size is the max length a snake could ever be. Lets just allocate that much space for the body locations.
    color_1: cart.NeopixelColor,
    color_2: cart.NeopixelColor,
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
    snake_body,
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

    const start_segment_1 = Vector{
        .origin = Coordinate{ .x = 25, .y = 25 },
        .direction = Direction.up,
    };
    const start_segment_2 = Vector{
        .origin = Coordinate{ .x = 25, .y = 30 },
        .direction = Direction.up,
    };
    const start_segment_3 = Vector{
        .origin = Coordinate{ .x = 25, .y = 35 },
        .direction = Direction.up,
    };

    snake_1 = .{
        .head_coord = .{ .x = 25, .y = 25 },
        .body_len = 3,
        .body_locations = .{ start_segment_1, start_segment_2, start_segment_3 } ++
            @as([map_size - 3]Vector, undefined),
        .color_1 = green,
        .color_2 = dgreen,
        .current_direction = .up,
        .score = 0,
    };

    map_grid = std.mem.zeroes([map_width][map_height]MapLocationType);
    addWallsToMap();
    addStartingPipsToMap();

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

// fn spawnPip() void {}

// fn tickPips() void {}

// fn drawPips() void {}

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

    const moveResult = MoveSnake(snake_1, snake_1.current_direction);

    switch (moveResult) {
        .collision => {},
        .collected_pip => {},
        .normal => {},
        .err => {},
    }
}

fn drawSnake() void {
    cart.trace("ss:draw-p");
    for (0..snake_1.body_len) |index| {
        const body_segment = snake_1.body_locations[index];
        drawSnakeSegment(body_segment.origin.x, body_segment.origin.y);
    }
}

fn drawSnakeSegment(x: i32, y: i32) void {
    cart.rect(.{
        .x = x,
        .y = y,
        .width = gridsquare_width,
        .height = gridsquare_width,
        .stroke_color = rgb565(snake_1.color_2),
        .fill_color = rgb565(snake_1.color_1),
    });
}

fn MoveSnake(snake: Snake, direction: Direction) MovementResult {
    _ = snake;
    _ = direction;
}

// fn collectedPip(snake: *Snake) void {
//     snake.score += 1;
//     increaseBodyLength(snake);
//     spawnPip(); //Should just reuse the pip we just collected...
// }

// fn increaseBodyLength(snake: *Snake) void {
//     snake.body_len += 1;
// }

fn gameOverConditionMet() bool {
    return false;
}

// fn resetGame() void {
//     snake_1.score = 0;
// }

// fn drawUi() void {
//     cart.trace("ss:draw-l");
//     if (snake_1.score > 0) {
//         var text: [32]u8 = undefined;
//         const txt = std.fmt.bufPrintSentinel(&text, "{}", .{snake_1.score}, 0) catch "-";
//         cart.text(.{
//             .str = txt,
//             .x = @intCast((cart.screen_width - cart.font_width * txt.len) / 2),
//             .y = 4,
//             .text_color = rgb565(white),
//         });
//     }
// }

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
                .snake_body => {},
                .snake_head => {},
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
            // resetGame();
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
    } else {
        // SELECT+DOWN = intentional reset (avoids accidental resets from SELECT noise).
        // SELECT alone no longer resets - was causing rapid resets to intro screen.
        if (stateTick > 60 and cart.controls.select and cart.controls.down) {
            select_held_frames +%= 1;
        } else {
            select_held_frames = 0;
        }
        if (select_held_frames >= 20) {
            //resetGame();
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
        if (gameOverConditionMet()) {
            gameState = .game_over;
            stateTick = 0;
            return;
        }
        drawGame();
    }

    mixer.update();
}

fn tickGame() void {
    cart.trace("ss:tg-snake");
    //tickSnake();
}

fn drawGame() void {
    drawSnake();
    //drawUi();
    drawMap();
}
