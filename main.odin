package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:sys/kqueue"
import "vendor:glfw"
import rl "vendor:raylib"


WINDOW_TITLE: cstring = "Triangulation by Ear Clipping "
LINE_COLOR: rl.Color = FG_COLOR
LINE_COLOR_DEBUG: rl.Color = rl.ColorAlpha(FG_COLOR, 0.2)
LINE_THICKNESS: f32 = 1.0
DASH_LENGTH: f32 = 5.0
DASH_GAP: f32 = 5.0
POINT_INNTER_RADIUS: f32 = 3.0
POINT_THICKNESS: f32 = 1.0
POINT_HOVER_CIRCLE: f32 = 10.0
POINT_OUTER_RADIUS: f32 = POINT_INNTER_RADIUS + POINT_THICKNESS
ASSETS_PATH := "./assets/"
BG_COLOR: rl.Color = rl.Color{0xF7, 0xF3, 0xEE, 0xFF}
BG_COLOR_2: rl.Color = rl.Color{0xDE, 0xDA, 0xD6, 0xFF}
PANEL_COLOR: rl.Color = rl.Color{0xDE, 0xDA, 0xD6, 0x66}
FG_COLOR: rl.Color = rl.Color{0x60, 0x5a, 0x52, 0xFF}
FG_ERROR_COLOR: rl.Color = rl.Color{0xFF, 0x69, 0x61, 0xFF}
CONFIG_OPTIONS := []cstring {
	"Close Polygon (C)",
	"Reset (R)",
	"Toggle Triangulation (T)",
	"Toggle Labels (L)",
	"Toggle Debug (D)",
}
MAX_POINTS :: 1024
MAX_POLYGONS :: 128


Point :: struct {
	pos:  rl.Vector2,
	next: ^Point,
	prev: ^Point,
}

PointList :: struct {
	size: u32,
	head: ^Point,
	tail: ^Point,
}

PointRef :: struct {
	list:  ^PointList,
	point: ^Point,
}

Triangle :: struct {
	a: rl.Vector2,
	b: rl.Vector2,
	c: rl.Vector2,
}

FontSize :: enum {
	SMALL  = 16,
	MEDIUM = 20,
	LARGE  = 24,
}

FontWeight :: enum {
	REGULAR,
	SEMIBOLD,
	MEDIUM,
	BOLD,
}

point_pool: [MAX_POINTS]Point
point_pool_index: int = 0
point_free_list: [MAX_POINTS]^Point
point_free_list_index: int = 0

width: i32 = 800
height: i32 = 600
font_file_cache := map[string]rl.Font{}
colors := []rl.Color {
	rl.RED,
	rl.GREEN,
	rl.ORANGE,
	rl.MAGENTA,
	rl.SKYBLUE,
	rl.VIOLET,
	rl.YELLOW,
	rl.PINK,
	rl.LIME,
	rl.DARKBLUE,
}

point_alloc :: proc() -> ^Point {
	if point_free_list_index > 0 {
		point_free_list_index -= 1
		recycled_point := point_free_list[point_free_list_index]
		return recycled_point
	} else {
		if point_pool_index >= MAX_POINTS {
			log.error("Out of points!")
			return nil
		}
		point := &point_pool[point_pool_index]
		point_pool_index += 1
		return point
	}
}

point_free :: proc(point: ^Point) {
	point_free_list[point_free_list_index] = point
	point_free_list_index += 1
}

point_list_free :: proc(list: ^PointList) {
	head := list.head
	it := &head
	for point in next_point(it) {
		point_free(point)
	}
}

get_font_file :: proc(weight: FontWeight) -> string {
	switch weight {
	case .REGULAR:
		return strings.concatenate({ASSETS_PATH, "jetbrains-mono-regular.ttf"})
	case .SEMIBOLD:
		return strings.concatenate({ASSETS_PATH, "jetbrains-mono-semibold.ttf"})
	case .MEDIUM:
		return strings.concatenate({ASSETS_PATH, "jetbrains-mono-medium.ttf"})
	case .BOLD:
		return strings.concatenate({ASSETS_PATH, "jetbrains-mono-bold.ttf"})
	}

	return ""
}

draw_text :: proc(
	text: cstring,
	position: rl.Vector2,
	font_size: FontSize = FontSize.SMALL,
	font_weight: FontWeight = FontWeight.REGULAR,
	color: rl.Color = FG_COLOR,
) {
	font_file := get_font_file(font_weight)
	font_id := fmt.tprintf("%s-%zu", font_file, font_size)
	font, exists := font_file_cache[font_id]
	if !exists {
		font_file_cstring := strings.clone_to_cstring(font_file)
		font = rl.LoadFontEx(font_file_cstring, cast(i32)font_size * 2, nil, 0)
		font_file_cache[font_id] = font
	}

	rl.DrawTextEx(font, text, position, cast(f32)font_size, 0.0, color)
}

measure_text :: proc(
	text: cstring,
	font_size: FontSize = FontSize.SMALL,
	font_weight: FontWeight = FontWeight.REGULAR,
) -> rl.Vector2 {
	font_file := get_font_file(font_weight)
	font_file_cstring := strings.clone_to_cstring(font_file)
	font, exists := font_file_cache[font_file]
	if !exists {
		font = rl.LoadFontEx(font_file_cstring, cast(i32)font_size * 2, nil, 0)
		font_file_cache[font_file] = font
	}

	return rl.MeasureTextEx(font, text, cast(f32)font_size, 0)
}

draw_point :: proc(point: rl.Vector2, is_hovered: bool = false) {
	if is_hovered {
		rl.DrawRing(
			point,
			POINT_INNTER_RADIUS + 2,
			POINT_OUTER_RADIUS + 2,
			0,
			360,
			100,
			LINE_COLOR,
		)
	} else {
		rl.DrawRing(point, POINT_INNTER_RADIUS, POINT_OUTER_RADIUS, 0, 360, 100, LINE_COLOR)
	}
}

draw_line :: proc(
	start: rl.Vector2,
	end: rl.Vector2,
	dashed: bool = false,
	color: rl.Color = LINE_COLOR,
) {
	if !dashed {
		rl.DrawLineEx(start, end, LINE_THICKNESS, color)
		return
	}

	dx := end.x - start.x
	dy := end.y - start.y
	length := math.sqrt(dx * dx + dy * dy)
	if length <= 0.0001 {
		return
	}

	dir := rl.Vector2{dx / length, dy / length}
	distance: f32 = 0.0
	for distance < length {
		segment_len := DASH_LENGTH
		if distance + segment_len > length {
			segment_len = length - distance
		}

		segment_start := rl.Vector2{start.x + dir.x * distance, start.y + dir.y * distance}
		segment_end := rl.Vector2 {
			start.x + dir.x * (distance + segment_len),
			start.y + dir.y * (distance + segment_len),
		}

		rl.DrawLineEx(segment_start, segment_end, LINE_THICKNESS, color)
		distance += DASH_LENGTH + DASH_GAP
	}
}

point_list_init := proc() -> PointList {
	return PointList{size = 0, head = nil, tail = nil}
}

point_list_append := proc(list: ^PointList, pos: rl.Vector2) {
	new_point := point_alloc()
	new_point^ = Point {
		pos  = pos,
		next = nil,
		prev = nil,
	}
	if list.size == 0 {
		list.head = new_point
		list.tail = new_point
	} else {
		new_point.prev = list.tail
		list.tail.next = new_point
		list.tail = new_point
	}
	list.size += 1
}

point_list_remove := proc(list: ^PointList, point: ^Point) {
	if point.prev != nil {
		point.prev.next = point.next
	} else {
		list.head = point.next
	}
	if point.next != nil {
		point.next.prev = point.prev
	} else {
		list.tail = point.prev
	}
	list.size -= 1
	point_free(point)
}

point_list_clone := proc(list: ^PointList) -> PointList {
	new_list := PointList {
		size = 0,
		head = nil,
		tail = nil,
	}
	it := list.head
	for point in next_point(&it) {
		point_list_append(&new_list, point.pos)
	}
	return new_list
}

point_list_reverse :: proc(list: ^PointList) {
	cursor := list.head
	for cursor != nil {
		next := cursor.next
		prev := cursor.prev
		cursor.prev = next
		cursor.next = prev
		cursor = next
	}
	list.head, list.tail = list.tail, list.head
}

next_point :: proc(point: ^^Point) -> (^Point, bool) {
	if point^ == nil {
		return nil, false
	}
	next := point^
	point^ = next.next
	return next, true
}


is_in_triangle :: proc(triangle: Triangle, p: rl.Vector2) -> bool {
	// https://blackpawn.com/texts/pointinpoly/
	v0 := triangle.c - triangle.a
	v1 := triangle.b - triangle.a
	v2 := p - triangle.a

	dot00 := rl.Vector2DotProduct(v0, v0)
	dot01 := rl.Vector2DotProduct(v0, v1)
	dot02 := rl.Vector2DotProduct(v0, v2)
	dot11 := rl.Vector2DotProduct(v1, v1)
	dot12 := rl.Vector2DotProduct(v1, v2)

	inv_denom := 1.0 / (dot00 * dot11 - dot01 * dot01)
	u := (dot11 * dot02 - dot01 * dot12) * inv_denom
	v := (dot00 * dot12 - dot01 * dot02) * inv_denom

	return (u >= 0) && (v >= 0) && (u + v < 1)
}

angle_ear :: proc(a: rl.Vector2, b: rl.Vector2, c: rl.Vector2) -> f32 {
	ba := a - b
	bc := c - b
	return angle_ccw(ba, bc)
}

// Counter clockwise angle between two vector
angle_ccw :: proc(a: rl.Vector2, b: rl.Vector2) -> f32 {
	dot := rl.Vector2DotProduct(a, b)
	det := a.x * b.y - a.y * b.x
	angle := math.atan2(det, dot)
	if angle < 0 {
		angle += 2 * math.PI
	}
	return angle
}

ear_clipping :: proc(polygon: ^PointList) -> ([dynamic]Triangle, bool) {
	head := polygon.head
	triangles := [dynamic]Triangle{}
	remaining_points := polygon.size
	no_ear_streak: u32 = 0
	area := polygon_area(polygon)
	if area == 0 {
		log.debug("Polygon has zero area, cannot triangulate.")
		return [dynamic]Triangle{}, false
	}
	is_ccw := area > 0
	for remaining_points >= 3 {
		// Get the next and previous points, wrapping around
		point := head
		prev := point.prev
		if prev == nil {
			prev = polygon.tail
		}
		next := point.next
		if next == nil {
			next = polygon.head
		}

		edge1 := point.pos - prev.pos
		edge2 := next.pos - point.pos
		cross := edge1.x * edge2.y - edge1.y * edge2.x
		is_convex := (cross > 0) == is_ccw
		if is_convex {
			triangle := Triangle {
				a = prev.pos,
				b = point.pos,
				c = next.pos,
			}

			// Check if any other point is inside the triangle
			// if so, then this is not an ear
			is_ear := true
			it := polygon.head
			for other_point in next_point(&it) {
				if other_point != prev && other_point != point && other_point != next {
					if is_in_triangle(triangle, other_point.pos) {
						is_ear = false
						break
					}
				}
			}

			if is_ear {
				// If the polygon is counter-clockwise, we need to swap b and c to maintain the correct winding order
				if !is_ccw {
					triangle.b, triangle.c = triangle.c, triangle.b
				}
				append(&triangles, triangle)
				point_list_remove(polygon, point)
				head = next
				remaining_points -= 1
				no_ear_streak = 0
				continue
			}
		}

		// Not an ear
		head = next
		no_ear_streak += 1
		if no_ear_streak >= remaining_points {
			log.debug(
				"Bug in ear clipping algorithm, visited all remaining points without finding an ear.",
				"no_ear_streak",
				no_ear_streak,
				"remaining",
				remaining_points,
			)
			return triangles, false
		}
	}

	return triangles, true
}

polygon_area :: proc(polygon: ^PointList) -> f32 {
	area: f32 = 0
	cursor := polygon.head
	if cursor == nil {
		return 0
	}
	for point in next_point(&cursor) {
		next := point.next
		if next == nil {
			next = polygon.head
		}
		area += point.pos.x * next.pos.y - next.pos.x * point.pos.y
	}
	return area * 0.5
}

Optional :: struct($T: typeid) {
	value:     $T,
	has_value: bool,
}

main :: proc() {
	context.logger = log.create_console_logger()
	rl.SetConfigFlags({.WINDOW_HIGHDPI, .MSAA_4X_HINT, .VSYNC_HINT})
	rl.InitWindow(width, height, WINDOW_TITLE)
	rl.SetExitKey(rl.KeyboardKey.KEY_NULL) // Disable default exit key (ESC)
	rl.SetTargetFPS(120)

	triangulations := [MAX_POLYGONS][dynamic]Triangle{}
	is_triangulation_invalid := [MAX_POLYGONS]bool{}
	polygons := [MAX_POLYGONS]PointList{}
	polygons_size := 0
	current_polygon := PointList {
		size = 0,
		head = nil,
		tail = nil,
	}
	current_triangulation := [dynamic]Triangle{}
	is_current_triangulation_invalid := false
	dragging_point_ref := PointRef{}
	triangulate := true
	show_labels := true
	debug := true

	for !rl.WindowShouldClose() {
		rl.BeginDrawing()
		defer rl.EndDrawing()
		rl.ClearBackground(BG_COLOR)

		mouse_pos := rl.GetMousePosition()
		mouse_pos.x = math.clamp(mouse_pos.x, 0, cast(f32)width - POINT_OUTER_RADIUS)
		mouse_pos.y = math.clamp(mouse_pos.y, 0, cast(f32)height - POINT_OUTER_RADIUS)
		hovered_point_ref := PointRef{}
		is_selecting := false
		message: string = ""
		message_buffer := [256]byte{}

		// Calculate key bindings panel size
		panel_font_size := FontSize.SMALL
		panel_font_weight := FontWeight.REGULAR
		max_text_width: f32 = 0
		total_text_height: f32 = 0
		for text in CONFIG_OPTIONS {
			measurement := measure_text(text, panel_font_size, panel_font_weight)
			max_text_width = math.max(max_text_width, measurement.x)
			total_text_height += measurement.y
		}
		key_bindings_panel := rl.Rectangle {
			x      = 5,
			y      = 5,
			width  = max_text_width + 10,
			height = total_text_height + 10,
		}

		// Hovering
		// Check collision with current_polygon
		it := current_polygon.head
		for point in next_point(&it) {
			if rl.CheckCollisionPointCircle(mouse_pos, point.pos, POINT_HOVER_CIRCLE) {
				hovered_point_ref = PointRef {
					list  = &current_polygon,
					point = point,
				}
				break
			}
		}
		// Check collision with other polygons
		for i in 0 ..< polygons_size {
			polygon := &polygons[i]
			it := polygon.head
			for point in next_point(&it) {
				if rl.CheckCollisionPointCircle(mouse_pos, point.pos, POINT_HOVER_CIRCLE) {
					hovered_point_ref = PointRef {
						list  = polygon,
						point = point,
					}
					break
				}
			}
		}

		// Dragging
		// Set dragging point
		if hovered_point_ref.point != nil &&
		   !(hovered_point_ref.point == current_polygon.head) &&
		   dragging_point_ref.point == nil &&
		   rl.IsMouseButtonDown(rl.MouseButton.LEFT) {
			dragging_point_ref = hovered_point_ref
		}
		if dragging_point_ref.point != nil && !rl.IsMouseButtonDown(rl.MouseButton.LEFT) {
			dragging_point_ref = PointRef{}
		}
		if dragging_point_ref.point != nil {
			if dragging_point_ref.point != current_polygon.head {
				dragging_point_ref.point.pos = mouse_pos
			}
		}

		// Right click to remove point
		if rl.IsMouseButtonPressed(rl.MouseButton.RIGHT) {
			if hovered_point_ref.point != nil {
				if hovered_point_ref.list.size > 3 {
					point_list_remove(hovered_point_ref.list, hovered_point_ref.point)
					if hovered_point_ref.point == dragging_point_ref.point {
						dragging_point_ref = PointRef{}
					}
					hovered_point_ref = PointRef{}
				}
			}
		}

		// Set mouse cursor
		rl.SetMouseCursor(.DEFAULT)
		if hovered_point_ref.point != nil {
			rl.SetMouseCursor(rl.MouseCursor.POINTING_HAND)
		}
		if dragging_point_ref.point != nil {
			rl.SetMouseCursor(rl.MouseCursor.RESIZE_ALL)
		}
		if is_selecting {
			rl.SetMouseCursor(rl.MouseCursor.CROSSHAIR)
		}

		// Create new point
		if dragging_point_ref.point == nil {
			if rl.IsMouseButtonPressed(rl.MouseButton.LEFT) {
				if current_polygon.size >= 3 && hovered_point_ref.point == current_polygon.head {
					polygons[polygons_size] = current_polygon
					polygons_size += 1
					current_polygon = PointList{}
				} else {
					point_list_append(&current_polygon, mouse_pos)
				}
			}
		}

		// Reset
		if rl.IsKeyPressed(rl.KeyboardKey.R) {
			triangulations = [MAX_POLYGONS][dynamic]Triangle{}
			for i in 0 ..< polygons_size {
				point_list_free(&polygons[i])
			}
			polygons_size = 0
			current_polygon = PointList{}
			current_triangulation = [dynamic]Triangle{}
		}

		// Close the polygon
		if rl.IsKeyPressed(rl.KeyboardKey.C) {
			if current_polygon.size >= 3 {
				polygons[polygons_size] = current_polygon
				polygons_size += 1
				current_polygon = PointList{}
			}
		}

		// Toggle show triangles
		if rl.IsKeyPressed(rl.KeyboardKey.T) {
		}

		// Cancel current polygon
		if rl.IsKeyPressed(rl.KeyboardKey.ESCAPE) {
			current_polygon = PointList{}
		}

		// Triangulate
		if rl.IsKeyPressed(rl.KeyboardKey.T) {
			triangulate = !triangulate
		}

		// Triangulate
		if rl.IsKeyPressed(rl.KeyboardKey.L) {
			show_labels = !show_labels
		}

		// Debug
		if rl.IsKeyPressed(rl.KeyboardKey.D) {
			debug = !debug
		}

		if triangulate {
			if current_polygon.size >= 3 {
				temporary_polygon := point_list_clone(&current_polygon)
				if dragging_point_ref.point == nil && hovered_point_ref.point == nil {
					point_list_append(&temporary_polygon, mouse_pos)
				}

				triangles, found := ear_clipping(&temporary_polygon)
				if found {
					message = ""
					is_current_triangulation_invalid = false
					current_triangulation = triangles
				} else {
					log.debug("Failed to triangulate polygon", triangles)
					message = "Failed to triangulate polygon"
					is_current_triangulation_invalid = true
					current_triangulation = triangles
				}
				point_list_free(&temporary_polygon)
			} else {
				current_triangulation = [dynamic]Triangle{}
			}

			for i in 0 ..< polygons_size {
				polygon := &polygons[i]
				temporary_polygon := point_list_clone(polygon)
				triangles, found := ear_clipping(&temporary_polygon)
				if found {
					message = ""
					is_triangulation_invalid[i] = false
					triangulations[i] = triangles
				} else {
					log.debug("Failed to triangulate polygon ", i + 1)
					message = fmt.bprintf(
						message_buffer[:],
						"Failed to triangulate polygon %d",
						i + 1,
					)
					is_triangulation_invalid[i] = true
					triangulations[i] = triangles
				}

				point_list_free(&temporary_polygon)
			}
		}

		// Drawing

		// Draw mouse point
		if dragging_point_ref.point == nil && !is_selecting {
			if current_polygon.size > 0 {
				draw_line(current_polygon.tail.pos, mouse_pos, true)
			}
			if hovered_point_ref.point == nil {
				draw_point(mouse_pos)
			}
		}

		// Draw current polygon
		it = current_polygon.head
		for point in next_point(&it) {
			if point != current_polygon.head {
				draw_line(point.prev.pos, point.pos)
			}
		}
		it = current_polygon.head
		i := 0
		for point in next_point(&it) {
			if hovered_point_ref.point == point {
				draw_point(point.pos, true)
			} else {
				draw_point(point.pos)
			}
			if show_labels {
				label_text := rl.TextFormat("%d", i)
				draw_text(
					label_text,
					rl.Vector2{point.pos.x + POINT_OUTER_RADIUS + 1, point.pos.y},
				)
			}
			i += 1
		}

		// Draw existing polygons
		for i in 0 ..< polygons_size {
			polygon := &polygons[i]
			it = polygon.head
			for point in next_point(&it) {
				if point != polygon.head {
					draw_line(point.prev.pos, point.pos)
				}
				if point == polygon.tail {
					draw_line(point.pos, polygon.head.pos)
				}
			}
			it = polygon.head
			i := 0
			for point in next_point(&it) {
				if hovered_point_ref.point == point {
					draw_point(point.pos, true)
				} else {
					draw_point(point.pos)
				}
				if show_labels {
					label_text := rl.TextFormat("%d", i)
					draw_text(
						label_text,
						rl.Vector2{point.pos.x + POINT_OUTER_RADIUS + 1, point.pos.y},
					)
				}
				i += 1
			}
		}

		// Draw triangles
		if triangulate {
			for triangle, i in current_triangulation {
				color := colors[i % len(colors)]
				color = rl.ColorAlpha(color, 0.1)

				if is_current_triangulation_invalid {
					if debug {
						draw_line(triangle.a, triangle.b, true, LINE_COLOR_DEBUG)
						draw_line(triangle.a, triangle.c, true, LINE_COLOR_DEBUG)
						draw_line(triangle.b, triangle.c, true, LINE_COLOR_DEBUG)
						rl.DrawTriangle(triangle.c, triangle.b, triangle.a, color)
					}
				} else {
					draw_line(triangle.a, triangle.b)
					draw_line(triangle.a, triangle.c)
					draw_line(triangle.b, triangle.c)
					rl.DrawTriangle(triangle.c, triangle.b, triangle.a, color)
				}
			}

			for i in 0 ..< polygons_size {
				polygon := polygons[i]
				triangles := triangulations[i]
				for triangle, i in triangles {
					color := colors[i % len(colors)]
					color = rl.ColorAlpha(color, 0.1)
					if is_triangulation_invalid[i] {
						if debug {
							draw_line(triangle.a, triangle.b, true, LINE_COLOR_DEBUG)
							draw_line(triangle.a, triangle.c, true, LINE_COLOR_DEBUG)
							draw_line(triangle.b, triangle.c, true, LINE_COLOR_DEBUG)
							rl.DrawTriangle(triangle.c, triangle.b, triangle.a, color)
						}
					} else {
						draw_line(triangle.a, triangle.b)
						draw_line(triangle.a, triangle.c)
						draw_line(triangle.b, triangle.c)
						rl.DrawTriangle(triangle.c, triangle.b, triangle.a, color)
					}
				}
			}
		}

		// Draw key bindings panel
		rl.DrawRectangleRec(key_bindings_panel, PANEL_COLOR)
		for text, i in CONFIG_OPTIONS {
			draw_text(
				text,
				rl.Vector2{5 + 5, cast(f32)panel_font_size * cast(f32)i + 5 + 5},
				panel_font_size,
				panel_font_weight,
			)
		}

		// Draw bottom bar
		rl.DrawRectangleRec(
			rl.Rectangle {
				x = 0,
				y = cast(f32)height - cast(f32)FontSize.SMALL * 2,
				width = cast(f32)width,
				height = cast(f32)FontSize.SMALL,
			},
			BG_COLOR_2,
		)

		fps := rl.GetFPS()
		fps_text := rl.TextFormat("FPS: %d", fps)
		fps_text_width := measure_text(fps_text).x
		mouse_pos_text := rl.TextFormat("(%.1f, %.1f)", mouse_pos.x, mouse_pos.y)
		points_text := rl.TextFormat("%d points", current_polygon.size)
		points_text_width := measure_text(points_text).x

		padding: f32 = 5

		draw_text(fps_text, rl.Vector2{padding, cast(f32)height - cast(f32)FontSize.SMALL * 2})
		draw_text(
			mouse_pos_text,
			rl.Vector2 {
				cast(f32)fps_text_width +  /* account for padding */padding +  /* gap */padding,
				cast(f32)height - cast(f32)FontSize.SMALL * 2,
			},
		)
		draw_text(
			points_text,
			rl.Vector2 {
				cast(f32)width - points_text_width - padding,
				cast(f32)height - cast(f32)FontSize.SMALL * 2,
			},
		)

		message_cstring := strings.clone_to_cstring(message)
		message_width := measure_text(message_cstring).x
		draw_text(
			message_cstring,
			rl.Vector2 {
				(cast(f32)width - message_width) / 2,
				cast(f32)height - cast(f32)FontSize.SMALL * 2,
			},
			FontSize.SMALL,
			FontWeight.BOLD,
			FG_ERROR_COLOR,
		)
	}

	rl.CloseWindow()
}
