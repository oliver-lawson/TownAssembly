; camera.inc.asm - centre the view on the player, clamped to world
;----------------------------------------------------------------
; the camera state itself (camera_x/y) lives in tilemap.inc.asm
; alongside the tile rendering that consumes it.  this file just
; owns the update logic
%ifndef CAMERA_INC
%define CAMERA_INC

%define WORLD_PIXEL_W		(MAP_WIDTH  * TILE_SIZE)
%define WORLD_PIXEL_H		(MAP_HEIGHT * TILE_SIZE)

section .text

;================================================================
; camera_update: centre camera on player, clamped to world bounds
;----------------------------------------------------------------
; camera_x = clamp(player_x - WINDOW_W/2, 0, max_camera_x)
; max_camera_x = max(0, WORLD_PIXEL_W - WINDOW_W) - if the world is
; narrower than the window we just stick the camera at 0
;================================================================
camera_update:
	; --- x axis ---
	mov eax, [player_x]
	sub eax, WINDOW_W / 2

	; max_camera_x = max(0, WORLD_PIXEL_W - WINDOW_W)
	mov ecx, WORLD_PIXEL_W - WINDOW_W
	test ecx, ecx
	jns .max_x_ok
	xor ecx, ecx
.max_x_ok:
	; clamp eax to [0, ecx]
	test eax, eax
	jns .x_not_neg
	xor eax, eax
.x_not_neg:
	cmp eax, ecx
	jle .x_done
	mov eax, ecx
.x_done:
	mov [camera_x], eax

	; --- y axis ---
	mov eax, [player_y]
	sub eax, WINDOW_H / 2

	mov ecx, WORLD_PIXEL_H - WINDOW_H
	test ecx, ecx
	jns .max_y_ok
	xor ecx, ecx
.max_y_ok:
	test eax, eax
	jns .y_not_neg
	xor eax, eax
.y_not_neg:
	cmp eax, ecx
	jle .y_done
	mov eax, ecx
.y_done:
	mov [camera_y], eax
	ret

%endif
