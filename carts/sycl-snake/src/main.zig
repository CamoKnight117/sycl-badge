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
const red = defColor(0xf82828);
const dred = defColor(0x3e0000);
const green = defColor(0x00ff00);
const dgreen = defColor(0x003c00);
const blue = defColor(0x7777ff);
const purp = defColor(0x820eef);

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

const Vector = struct {
    origin: Coordinate,
    direction: Direction,
};

const Snake = struct {
    head_coord: Coordinate,
    body_len: u8,
    body_locations: [map_size]Vector, //map size is the max length a snake could ever be. Lets just allocate that much space for the body locations.
    color_1: green,
    color_2: dgreen,
    current_direction: Direction,
    score: u16,
};

const Pip = struct {
    coord: Coordinate,
    color: green,
};

const Wall = struct {
    color: red,
    //Other types necessary for walls? Thickness? Sprite?
};

const Direction = enum {
    up,
    down,
    left,
    right,
};

const MovementResult = enum {
    collision,
    collected_pip,
    normal,
    err,
};

const map_width: u8 = 20; //map width in grid squares
const map_height: u8 = 20; //map height in grid squares
const map_size = map_width * map_height; //total grid squares
const gridsquare_width = 5; //pixel width of grid squares
const start_pips = 2;
const max_pips = 10;
var snake_1: Snake = undefined;
var snake_2: Snake = undefined;
var pips: [max_pips]Pip = undefined;
var map_grid: [map_height][map_width]u8 = undefined;

var mixer: cart.mixer.Mixer(.{}) = .{};

pub fn start() void {
    rand = std.Random.DefaultPrng.init(5831);

    snake_1 = .{ .head_x = 0, .head_y = 0, .body_len = 3, .body_locations = .{
        .{},
    } };

    // Enable vsync but tune the framerate to be as fast as possible for the app timing
    cart.set_vsync_dynamic();

    // Use the OS to clear every frame to black before it gets to the cart
    cart.set_double_buffer_mode(.{ .clear_full_frame = rgb565(black) });

    mixer.start_audio();
}

fn spawnPip() void {}

fn tickPips() void {}

fn drawPips() void {}

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
    for (snake_1.body_locations) |body_segment| {
        cart.oval(.{
            .x = body_segment.origin.x,
            .y = body_segment.origin.y,
            .width = 3,
            .height = 3,
            .stroke_color = rgb565(snake_1.color_1),
            .fill_color = rgb565(snake_1.color_2),
        });
    }
}

fn MoveSnake(snake: Snake, direction: Direction) MovementResult {
    _ = snake;
    _ = direction;
}

fn collectedPip(snake: *Snake) void {
    snake.score += 1;
    increaseBodyLength(snake);
    spawnPip(); //Should just reuse the pip we just collected...
}

fn increaseBodyLength(snake: *Snake) void {
    snake.body_len += 1;
}

fn reset_game() void {
    snake_1.score = 0;
}

fn draw_ui() void {
    cart.trace("ss:draw-l");
    if (player.score > 0) {
        var text: [32]u8 = undefined;
        const txt = std.fmt.bufPrintSentinel(&text, "{}", .{player.score}, 0) catch "-";
        cart.text(.{
            .str = txt,
            .x = @intCast((cart.screen_width - cart.font_width * txt.len) / 2),
            .y = 4,
            .text_color = rgb565(white),
        });
    }
}

fn draw_walls() void {
    cart.trace("ss:draw-w");
    //Top wall
    cart.rect(.{
        .x = 0,
        .y = 0,
        .width = map_width * gridsquare_width,
        .height = gridsquare_width,
        .stroke_color = green,
        .fill_color = blue,
    });
    //Bottom wall
    cart.rect(.{
        .x = 0,
        .y = gridsquare_width * (map_height - 1),
        .width = map_width * gridsquare_width,
        .height = gridsquare_width,
        .stroke_color = green,
        .fill_color = blue,
    });
    //Left wall
    cart.rect(.{
        .x = 0,
        .y = 0,
        .width = gridsquare_width,
        .height = map_height * gridsquare_width,
        .stroke_color = green,
        .fill_color = blue,
    });
    //Right wall
    cart.rect(.{
        .x = gridsquare_width * (map_width - 1),
        .y = 0,
        .width = gridsquare_width,
        .height = map_height * gridsquare_width,
        .stroke_color = green,
        .fill_color = blue,
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

fn draw_intro_text() void {
    const y_start = (cart.screen_height - (cart.font_height + spacing * (introText.len - 1))) / 2;
    cart.text(.{
        .str = line,
        .x = @as(i32, @intCast((cart.screen_width - cart.font_width * line.len) / 2)) + shakex[i],
        .y = @as(i32, @intCast(y_start + spacing * i)) + shakey[i],
        .text_color = rgb565(zig),
    });
}

//CAM CONTINUE IMPLEMENTING FROM HERE
