global main
default rel

%include "sdl.inc.asm"
%include "random.inc.asm"
%include "framebuffer.inc.asm"
%include "texture.inc.asm"
%include "blit.inc.asm"
%include "tilemap.inc.asm"
%include "worldgen.inc.asm"
%include "entity.inc.asm"
%include "entity_player.inc.asm"
%include "debug.inc.asm"

section .data
	window_title		db "Town Assembly", 0
	tile_ppm_file		db "res/tiles.ppm", 0
	sprites_ppm_file	db "res/sprites.ppm", 0
	scale_quality_hint  db "SDL_RENDER_SCALE_QUALITY", 0
	scale_quality_value db "0", 0 ; "0" = nearest-neighbour

	%define TILES_X		  (WINDOW_W  / TILE_SIZE)
	%define TILES_Y		  (WINDOW_H / TILE_SIZE)

	; -- sprite/movement constants --
	%define SPRITE_SIZE			16
	%define SPRITE_COLOR_KEY	0xFFFF00FF ; magenta
	%define WORLD_PIXEL_W		(MAP_WIDTH  * TILE_SIZE)
	%define WORLD_PIXEL_H		(MAP_HEIGHT * TILE_SIZE)
	move_step			equ 1				; player px/frame
	; -- SDL error messages --
	; 10 = \n, 0 = C-style string terminator:
	err_init_msg		db "SDL_Init failed", 10, 0 
	err_window_msg		db "SDL_CreateWindow failed", 10, 0
	err_renderer_msg	db "SDL_CreateRenderer failed", 10, 0
	err_texture_msg		db "SDL_CreateTexture failed", 10, 0
	err_ppm_msg			db "load_ppm failed", 10, 0

	; HUD text
	hud_label_fps		db "fps", 0
	hud_label_iters		db "iters", 0
	hud_label_seed		db "seed", 0
	hud_help			db "F3 hud  F5 restart  ESC quit", 0

	; log messages
	log_msg_started		db 0x1, " world generated! ", 0x3, 0
	log_msg_restart		db "regenerated world", 0
	log_msg_itered		db "iterated cellular automata", 0
	log_msg_hud_toggles	db "hud toggled", 0

; SDL_GetKeyboardState
; returns ptr to a uint8[] indexed by scancode
; ptr is stable, so we're caching it once after SDL_Init
; into the sdl_keystate below
extern SDL_GetKeyboardState

section .bss ; uninitialised buffers
	alignb 8
	sdl_window			resq 1
	sdl_renderer 		resq 1
	sdl_texture			resq 1
	sdl_keystate		resq 1
	current_scale		resq 1

	; input state
		; - sustained -
	key_quit			resb 1
		; - one shots -
	key_toggle_pressed	resb 1
	key_iterateworld_pressed	resb 1
	key_restart_pressed	resb 1

	; player state - source of truth TODO: extract for collision etc
	alignb 4
	player_x			resd 1 ; pixel coords (centre of sprite atm)
	player_y			resd 1
	player_facing		resd 1 ; FACE_DOWN/UP/etc (entity.inc.asm)
	player_anim_phase	resd 1 ; 0 or 1 - which walk frame atm
	player_anim_timer	resd 1 ; counts up to ANIM_PERIOD
	player_moved		resb 1 ; did we move this frame?

	; fps tracking
	alignb 4
	frame_count			resd 1
	last_fps_ticks		resd 1	; SDL_GetTicks value @ last fps sample
	last_fps_frame		resd 1	; frame_count @ last fps sample
	current_fps			resd 1	; final computed fps for display
	current_seed		resd 1	; stash for HUD

	alignb 8
	event_buf			resb SDL_EVENT_SIZE
section .text ; begin!

main: ; stack alignment:
	push rbp	 ; align stack to 16, "frame pointer" convention
	mov rbp, rsp ; tell debugger where the frame is

	; load tile atlas - tiles.ppm
	; must be 16^2px tiles, and match tile types in tilemap.inc.asm
	lea rdi, [atlas_tex]
	lea rsi, [tile_ppm_file]
	call load_ppm_texture
	test eax, eax
	jnz .fail_ppm

	; load sprite sheet - sprites.ppm
	; layout: row of 16x16 sprites, slots 0..N magenta = transparent
	; expected slots atm:
	; 0=down-facing|1=up-facing|2=left-walk_1|3:left-walk_2
	lea rdi, [sprites_tex]
	lea rsi, [sprites_ppm_file]
	call load_ppm_texture
	test eax, eax
	jnz .fail_ppm

	; seed rng and generate world
	;call rng_seed_from_time
	mov [rng_state], byte 1
	mov eax, [rng_state]
	mov [current_seed], eax ; store current seed for HUD
	call generate_world
	;call init_tilemap_test

	; wipe the entity table - no entities yet, just scaffolding for now.
	; later steps will spawn the player + NPCs after this.
	call entity_clear_all

	; player start/defaults - centre of map facing down for now
	mov dword [player_x], WORLD_PIXEL_W / 2
	mov dword [player_y], WORLD_PIXEL_H / 2
	mov dword [player_facing], FACE_DOWN
	mov dword [player_anim_phase], 0
	mov dword [player_anim_timer], 0
	mov byte  [player_moved], 0

	lea rdi, [log_msg_started]
	call debug_log

	; set video scale
	mov dword [current_scale], 2

	; SDL hints - must be done before SDL_INIT_VIDEO
	lea rdi, [scale_quality_hint]
	lea rsi, [scale_quality_value]
	call SDL_SetHint

	; setup SDL
	mov edi, SDL_INIT_VIDEO
	call SDL_Init
	test eax, eax
	jnz .fail_init

	; cache the keyboard-state pointer
	; SDL apparently guarantees this stays valid for our window's
	; lifetime, so we only need to fetch it once
	; passing null for the optional numkeys-out param
	xor edi, edi
	call SDL_GetKeyboardState
	mov [sdl_keystate], rax

	; window titl, pos, scale
	lea rdi, [window_title]
	mov esi, SDL_WINDOWPOS_CENTERED
	mov edx, SDL_WINDOWPOS_CENTERED
	mov ecx, WINDOW_W * 2 ; default scale
	mov r8d, WINDOW_H * 2
	mov r9d, SDL_WINDOW_SHOWN
	call SDL_CreateWindow
	test rax, rax
	jz .fail_window
	mov [sdl_window], rax ; store new pointer to window

	mov rdi, [sdl_window]
	mov esi, -1
	mov edx, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC
	call SDL_CreateRenderer
	test rax, rax
	jz .fail_renderer
	mov [sdl_renderer], rax ; store pointer to renderer

	; + tell SDL the renderer's logical size if WINDOW_W * WINDOW_H
	; this means RenderCopy with NULL dst rect will scale our texture
	; to fill the window, regardless of window size
	mov rdi, [sdl_renderer]
	mov esi, WINDOW_W
	mov edx, WINDOW_H
	call SDL_RenderSetLogicalSize

	; create gpu streaming texture we'll upload to each frame
	mov rdi, [sdl_renderer]
	mov esi, SDL_PIXELFORMAT_ARGB8888
	; SDL_TEXTUREACCESS_STREAMING for telling SDL we're
	; uploading new pixels to this texture often, not STATIC
	; or TARGET.  seems best approach
	mov edx, SDL_TEXTUREACCESS_STREAMING
	mov ecx, WINDOW_W
	mov r8d, WINDOW_H
	call SDL_CreateTexture
	test rax, rax
	jz .fail_texture
	mov [sdl_texture], rax

	; grab the starting tick count for FPS calc
	call SDL_GetTicks
	mov [last_fps_ticks], eax

	; --- main loop ---
.main_loop:
	call process_sdl_events

	cmp byte [key_quit], 0
	jne .cleanup

	; --- handle one shot keys ---

	; F4: iterate wordlgen CA
	cmp byte [key_iterateworld_pressed], 0
	je .no_iterateworld
	mov byte [key_iterateworld_pressed], 0
	; iterate world
	call iterate_world
	lea rdi, [log_msg_itered]
	call debug_log


.no_iterateworld:
	; F5: restart game
	cmp byte [key_restart_pressed], 0
	je .no_restart
	mov byte [key_restart_pressed], 0
	; restart pressed
	;call rng_seed_from_time
	call reset_world_iterations
	call rng_next
	mov eax, [rng_state]
	mov [current_seed], eax
	call generate_world
	call entity_clear_all
	; place the player at centre again with new sprite defaults
	mov dword [player_x], WORLD_PIXEL_W / 2
	mov dword [player_y], WORLD_PIXEL_H / 2
	mov dword [player_facing], FACE_DOWN
	mov dword [player_anim_phase], 0
	mov dword [player_anim_timer], 0
	mov byte  [player_moved], 0
	lea rdi, [log_msg_restart]
	call debug_log

.no_restart:
	; F3: toggle HUD
	cmp byte [key_toggle_pressed], 0
	je .no_toggle
	mov byte [key_toggle_pressed], 0
	call debug_toggle
	lea rdi, [log_msg_hud_toggles]
	call debug_log

.no_toggle:
	; --- player movement ---
	call update_player_input
	; --- fps calculation ---
	; sampling every 500ms and scaling up
	;
	; C equiv:
	;	uint32_t now = SDL_GetTicks();
	;	uint32_t elapsed = now - last_fps_ticks;
	;	if (elapsed >= 500) {
	;		uint32_t frames = frame_count - last_fps_frame;
	;		current_fps = frames * 1000 / elapsed;
	;		last_fps_ticks = now;
	;		last_fps_frame = frame_count;
	;	}
	call SDL_GetTicks
	mov ecx, eax				; ecx = now
	mov r11d, ecx
	sub r11d, [last_fps_ticks]	; r11d = elapsed ms
	cmp r11d, 500
	jl .fps_done
	; enough time has passed - compute fps
	mov eax, [frame_count]
	sub eax, [last_fps_frame]	; eax = frames since last sample
	imul eax, 1000				; scale to per-second
	xor edx, edx
	div r11d					; eax = fps
	mov [current_fps], eax
	mov [last_fps_ticks], ecx	; reset sample window
	mov eax, [frame_count]
	mov [last_fps_frame], eax
.fps_done:

	; --- render ---
	lea rdi, [atlas_tex]
	call draw_tilemap 

	; player on top of tiles
	call draw_player

	; ------ draw debug hud (if enabled) ------
	call is_debug_hud_enabled
	test eax, eax
	jz .skip_hud_draw

	;top row: fps counter
	mov edi, 4 ; x
	mov esi, 4 ; y
	mov edx, 0xFF004400 ; some green, would be cool to speed-tint
	lea rcx, [hud_label_fps]
	mov r8d, [current_fps]
	call debug_print_label_int
	; iterations
	add eax, 8 ; bit of a gap between labels
	mov edi, eax
	mov esi, 4
	mov edx, 0xFF0033AA
	lea rcx, [hud_label_iters]
	mov r8d, [ca_iterations_count]
	call debug_print_label_int
	; seed
	add eax, 8 ; bit of a gap between labels
	mov edi, eax
	mov esi, 4
	mov edx, 0xFF000000
	lea rcx, [hud_label_seed]
	mov r8d, [current_seed]
	call debug_print_label_int

	; second line: help text
	mov edi, 4
	mov esi, 14
	mov edx, 0xFF000000;
	lea rcx, [hud_help]
	call debug_print

	; log lines at the bottom
	call debug_render_log
	; -------- end hud (if enabled) -------
	.skip_hud_draw:

	inc dword [frame_count]

	; upload framebuffer to gpu texture
	mov rdi, [sdl_texture]
	xor rsi, rsi ; NULL - update whole texture, not a rect of it
	lea rdx, [framebuffer]
	mov ecx, FB_PITCH
	call SDL_UpdateTexture ; (texture, NULL, pixels, pitch)

	mov rdi, [sdl_renderer]
	call SDL_RenderClear

	; SDL_RenderCopy(renderer, texture, NULL, NULL):
	mov rdi, [sdl_renderer]
	mov rsi, [sdl_texture]
	xor rdx, rdx
	xor rcx, rcx
	call SDL_RenderCopy

	mov rdi, [sdl_renderer]
	call SDL_RenderPresent

	;mov edi, 16 ; delay ms, even if we have vsync enabled
	;call SDL_Delay

	jmp .main_loop

.cleanup:
	; === end main ===
	lea rdi, [atlas_tex]
	call free_texture
	lea rdi, [sprites_tex]
	call free_texture
	mov rdi, [sdl_texture]
	call SDL_DestroyTexture
	mov rdi, [sdl_renderer]
	call SDL_DestroyRenderer
	mov rdi, [sdl_window]
	call SDL_DestroyWindow
	call SDL_Quit
	xor eax, eax ; 0
	leave 	; mov rsp,rbp and pop rbp to restore stack
	ret		; returns to crt1.o which calls exit()

.fail_ppm:
	; could be either atlas or sprites load that failed; free both
	; free_texture seems null-safe so an uninit struct is fine
	lea rdi, [atlas_tex]
	call free_texture
	lea rdi, [sprites_tex]
	call free_texture
	lea rdi, [err_ppm_msg]
	call print_error
	mov eax, 1
	leave
	ret
.fail_init:
	lea rdi, [err_init_msg]
	call print_error
	lea rdi, [atlas_tex]
	call free_texture
	lea rdi, [sprites_tex]
	call free_texture
	mov eax, 1 ; exit code
	leave
	ret
.fail_window:
	lea rdi, [err_window_msg]
	call print_error
	lea rdi, [atlas_tex]
	call free_texture
	lea rdi, [sprites_tex]
	call free_texture
	call SDL_Quit
	mov eax, 1
	leave
	ret
.fail_renderer:
	lea rdi, [err_renderer_msg]
	call print_error
	lea rdi, [atlas_tex]
	call free_texture
	lea rdi, [sprites_tex]
	call free_texture
	mov rdi, [sdl_window]
	call SDL_DestroyWindow
	call SDL_Quit
	mov eax, 1
	leave
	ret
.fail_texture:
	lea rdi, [err_texture_msg]
	call print_error
	lea rdi, [atlas_tex]
	call free_texture
	lea rdi, [sprites_tex]
	call free_texture
	mov rdi, [sdl_renderer]
	call SDL_DestroyRenderer
	mov rdi, [sdl_window]
	call SDL_DestroyWindow
	call SDL_Quit
	mov eax, 1
	leave
	ret

; -- process_sdl_events --
; drain SDL event quere & update key state
;
; one-shot (latched) key state:
;	key_toggle_pressed set to 1 on keydown, acted on by main loop
;   and then cleared.  so it's a "do once" latch
; sustained: eg key_quit, stays set once triggered  
process_sdl_events:
	push rbp
	mov rbp, rsp
.poll:
	lea rdi, [event_buf]
	call SDL_PollEvent
	test eax, eax
	jz .done				; queue empty

	mov eax, [event_buf + SDL_EVENT_TYPE_OFF]
	cmp eax, SDL_QUIT_EVENT
	je .got_quit
	cmp eax, SDL_KEYDOWN_EVENT
	je .got_keydown
	jmp .poll				; ignore other events

.got_quit:
	mov byte [key_quit], 1
	jmp .poll

.got_keydown:
	mov eax, [event_buf + SDL_EVENT_SCANCODE_OFF]
	cmp eax, SCANCODE_ESCAPE
	je .key_escape
	cmp eax, SCANCODE_F3
	je .key_f3
	cmp eax, SCANCODE_F4
	je .key_f4
	cmp eax, SCANCODE_F5
	je .key_f5
	jmp .poll

.key_escape:
	mov byte [key_quit], 1
	jmp .poll
.key_f3:
	mov byte [key_toggle_pressed], 1
	jmp .poll
.key_f4:
	mov byte [key_iterateworld_pressed], 1
	jmp .poll
.key_f5:
	mov byte [key_restart_pressed], 1
	jmp .poll

.done:
	pop rbp
	ret

;================================================================
; print_error: writes a null-terminated string to stderr
;----------------------------------------------------------------
; in: rdi = string pointer
;================================================================
print_error:
	push rbp
	mov rbp, rsp
	mov rsi, rdi
	xor rcx, rcx ; rsi, rcx are caller saved, can clobber
.strlen:
	cmp byte [rsi + rcx], 0
	je .got_len
	inc rcx
	jmp .strlen
.got_len:
	mov rax, 1
	mov rdx, rcx
	mov rdi, 2
	syscall
	pop rbp
	ret

;================================================================
; update_player_input: poll arrow keys and move/animate
;----------------------------------------------------------------
; runs once per frame. checks each dir independently for diags
; sets player_facing to the most-recent pressed direction for now
; updates player_anim_phase based on whether anything moved
;================================================================
update_player_input:
	push rbp
	mov rbp, rsp

	mov byte [player_moved], 0

	; -- left? --
	mov rax, [sdl_keystate]
	movzx ecx, byte [rax + SCANCODE_LEFT]
	test ecx, ecx
	jz .not_left
	mov dword [player_facing], FACE_LEFT
	mov edi, -move_step
	xor esi, esi
	call try_move
.not_left:
	; -- right? --
	mov rax, [sdl_keystate]
	movzx ecx, byte [rax + SCANCODE_RIGHT]
	test ecx, ecx
	jz .not_right
	mov dword [player_facing], FACE_RIGHT
	mov edi, move_step
	xor esi, esi
	call try_move
.not_right:
	; -- up? --
	mov rax, [sdl_keystate]
	movzx ecx, byte [rax + SCANCODE_UP]
	test ecx, ecx
	jz .not_up
	mov dword [player_facing], FACE_UP
	xor edi, edi
	mov esi, -move_step
	call try_move
.not_up:
	; -- down? --
	mov rax, [sdl_keystate]
	movzx ecx, byte [rax + SCANCODE_DOWN]
	test ecx, ecx
	jz .not_down
	mov dword [player_facing], FACE_DOWN
	xor edi, edi
	mov esi, move_step
	call try_move
.not_down:

	; --- animation ---
	; if moved this frame?: tick the timer, toggle phase on overflow
	; if idle?: reset to phase 0 so we always come to rest in pose 0
	cmp byte [player_moved], 0
	je .anim_idle
	inc dword [player_anim_timer]
	cmp dword [player_anim_timer], ANIM_PERIOD
	jl .anim_done
	mov dword [player_anim_timer], 0
	xor dword [player_anim_phase], 1
	jmp .anim_done
.anim_idle:
	mov dword [player_anim_timer], 0
	mov dword [player_anim_phase], 0
.anim_done:
	pop rbp
	ret

;================================================================
; try_move: nudge the player by (dx, dy), clamping to world bounds
;----------------------------------------------------------------
; TODO: fairly placeholder-y, need to modulate speed and do
; collision handling
;----------------------------------------------------------------
; in: edi = dx, esi = dy
;================================================================
try_move:
	; new_x = clamp(player_x + dx, 0, WORLD_PIXEL_W - 1)
	mov eax, [player_x]
	add eax, edi
	test eax, eax
	jns .x_not_neg
	xor eax, eax
.x_not_neg:
	cmp eax, WORLD_PIXEL_W - 1
	jle .x_in_range
	mov eax, WORLD_PIXEL_W - 1
.x_in_range:
	cmp eax, [player_x]
	je .x_unchanged
	mov [player_x], eax
	mov byte [player_moved], 1
.x_unchanged:

	; new_y = clamp(player_y + dy, 0, WORLD_PIXEL_H - 1)
	mov eax, [player_y]
	add eax, esi
	test eax, eax
	jns .y_not_neg
	xor eax, eax
.y_not_neg:
	cmp eax, WORLD_PIXEL_H - 1
	jle .y_in_range
	mov eax, WORLD_PIXEL_H - 1
.y_in_range:
	cmp eax, [player_y]
	je .y_unchanged
	mov [player_y], eax
	mov byte [player_moved], 1
.y_unchanged:
	ret

;================================================================
; draw_player: blit the player sprite at (player_x, player_y)
;----------------------------------------------------------------
; sprite slot pick (4-frame layout: 0 d, 1 u, 2 left-A, 3 left-B):
;	facing DOWN		-> slot 0, flip alternates with phase
;	facing UP		-> slot 1, flip alternates with phase
;	facing LEFT		-> slot 2 or 3 by phase, no flip
;	facing RIGHT	-> slot 2 or 3 by phase, flipped
;
; player_x/y are the centre of the sprite for now,
; so dst_x = x - SPRITE_SIZE/2
; 
; TODO: extract to some generic draw_entities for other NPCs
;================================================================
draw_player:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	push r13
	sub rsp, 8		; align

	; pick pose
	; r12d = slot, r13d = flip? (0/1)
	xor r12d, r12d
	xor r13d, r13d
	mov eax, [player_facing]
	cmp eax, FACE_DOWN
	je .pp_down
	cmp eax, FACE_UP
	je .pp_up
	cmp eax, FACE_LEFT
	je .pp_left
	; right
	mov r12d, 2
	add r12d, [player_anim_phase]
	mov r13d, 1
	jmp .pose_done
.pp_left:
	mov r12d, 2
	add r12d, [player_anim_phase]
	jmp .pose_done
.pp_down:
	mov r13d, [player_anim_phase]
	jmp .pose_done
.pp_up:
	mov r12d, 1
	mov r13d, [player_anim_phase]
.pose_done:

	; dst_x = player_x - SPRITE_SIZE/2 (player_x is sprite centre)
	mov ebx, [player_x]
	sub ebx, SPRITE_SIZE/2

	; dst_y = player_y - SPRITE_SIZE/2 (in eax for the push)
	mov eax, [player_y]
	sub eax, SPRITE_SIZE/2

	; --- push stack args for blit_texture_rect_keyed ---
	; layout the blit expects (relative to its rbp):
	;   [rbp+16] = dst_y, [rbp+24] = flip, [rbp+32] = key
	; push rtl: key, flip, dst_y
	; 3 pushes = 24 bytes:  16-aligned coming in (caller convention),
	; so add an 8-byte pad first to land 16-aligned at the call
	sub rsp, 8					; alignment pad
	mov rcx, SPRITE_COLOR_KEY
	push rcx					; key
	movsxd rdx, r13d
	push rdx					; flip
	cdqe						; dst_y currently in eax; sign-extend
	push rax					; dst_y

	; register args
	lea rdi, [sprites_tex]
	mov esi, r12d
	imul esi, SPRITE_SIZE		; src_x
	xor edx, edx				; src_y = 0
	mov ecx, SPRITE_SIZE		; src_w
	mov r8d, SPRITE_SIZE		; src_h
	mov r9d, ebx				; dst_x

	call blit_texture_rect_keyed
	add rsp, 32					; 24 args + 8 pad

	add rsp, 8
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

