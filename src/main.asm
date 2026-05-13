global main
default rel

%include "sdl.inc.asm"
%include "random.inc.asm"
%include "framebuffer.inc.asm"
%include "texture.inc.asm"
%include "blit.inc.asm"
%include "autotile.inc.asm"
%include "tilemap.inc.asm"
%include "entity.inc.asm"
%include "entity_player.inc.asm"
%include "worldgen.inc.asm"
%include "debug.inc.asm"
%include "console.inc.asm"
%include "inventory.inc.asm"
%include "hud.inc.asm"

section .data
	window_title		db "Town Assembly", 0
	tile_ppm_file		db "res/tiles.ppm", 0
	sprites_ppm_file	db "res/sprites.ppm", 0
	icons_ppm_file		db "res/icons.ppm", 0
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
	hud_help			db "` console F3 hud F5 restart i inv 1-5 hotbar", 0

	; log messages
	log_msg_started		db 0x1, " world generated! ", 0x3, 0
	log_msg_restart		db "regenerated world", 0
	log_msg_itered		db "iterated cellular automata", 0
	log_msg_hud_toggles	db "hud toggled", 0

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
	key_action_pressed	resb 1
	key_inv_pressed		resb 1
	key_close_pressed	resb 1
	; hotbar select: 0 means nothing pressed, otherwise the digit
	; pressed (1..N).  cleared after consumed
	key_hotbar_digit	resb 1


	; player state - source of truth TODO: extract for collision etc
	alignb 4
	player_x			resd 1 ; pixel coords (centre of sprite atm)
	player_y			resd 1
	player_facing		resd 1 ; FACE_DOWN/UP/etc (entity.inc.asm)
	player_anim_phase	resd 1 ; 0 or 1 - which walk frame atm
	player_anim_timer	resd 1 ; counts up to ANIM_PERIOD
	player_moved		resb 1 ; did we move this frame?
	; something like player_placing/interacting?

	; stats + inventory used by the HUD bar. words for now (max ~65k)
	; reset to defaults in setup_world_entities so F5 clears them too
	alignb 2
	player_hp			resw 1
	player_hp_max		resw 1
	player_res_wood		resw 1
	player_res_stone	resw 1
	player_res_food		resw 1
	player_res_gold		resw 1

	; movement accumulator for fractional-speed tiles:
	; each move attempt adds the destination tile's speed percent:
	; when it reaches 100 we apply the step and subtract
	; eg water at 50 = step every 2 frames.
	alignb 4
	move_accum			resd 1

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

	; load HUD icon sheet - icons.ppm
	; slots: 0 hp, 1 wood, 2 stone, 3 food, 4 gold
	; no colour key atm as keeping hud bg solid
	lea rdi, [icons_tex]
	lea rsi, [icons_ppm_file]
	call load_ppm_texture
	test eax, eax
	jnz .fail_ppm

	; seed rng and generate world
	;call rng_seed_from_time
	mov [rng_state], byte 1
	mov eax, [rng_state]
	mov [current_seed], eax ; store current seed for HUD
	call generate_world

	; player init
	call place_player_on_floor
	mov byte  [player_moved], 0
	call setup_world_entities ; place NPCs
	call inv_init ; set up inventory
	; CHEAT: give starting items so I don't have to keep crafting..
	mov word [inv_item_count + ITEM_TORCH * 2], 12
	mov word [inv_item_count + ITEM_CHAIR * 2], 8
	mov word [inv_item_count + ITEM_BED * 2], 8
	mov word [inv_item_count + ITEM_WOOD_FLOOR * 2], 24
	mov word [inv_item_count + ITEM_WOOD_WALL * 2], 16
	mov word [inv_item_count + ITEM_WOOD_DOOR * 2], 4

	lea rdi, [log_msg_started]
	call debug_log

	; set video scale
	mov dword [current_scale], 3

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
	mov ecx, WINDOW_W * 3 ; default scale
	mov r8d, WINDOW_H * 3
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

	; mirror OS-level mouse position into our logical pixel coords
	; once per frame, so any UI code that hit-tests this frame is
	; consistent
	call update_mouse_state

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
	call restart_world

.no_restart:
	; F3: toggle HUD
	cmp byte [key_toggle_pressed], 0
	je .no_toggle
	mov byte [key_toggle_pressed], 0
	call debug_toggle
	lea rdi, [log_msg_hud_toggles]
	call debug_log

.no_toggle:

	; I toggles the inventory screen
	;handled before the action key to avoid clash
	cmp byte [key_inv_pressed], 0
	je .no_inv
	mov byte [key_inv_pressed], 0
	call inv_toggle
.no_inv:

	; hotbar number key: select the slot's item.  ignored if the
	; inventory is open so 1..9 typing in the console doesn't
	; trigger placement
	movzx eax, byte [key_hotbar_digit]
	test eax, eax
	jz .no_hotbar_digit
	; consume the one-shot before any calls clobber registers
	mov byte [key_hotbar_digit], 0
	push rax					; stash the digit
	call inv_is_open
	pop rcx						; rcx = the digit
	test eax, eax
	jnz .no_hotbar_digit			; inv up - drop the press
	; map digit (1..N) to ITEM_* (1..ITEM_COUNT-1).  hotbar slot
	; n == item id n, simple as that for now
	mov al, cl
	call hotbar_set_select
.no_hotbar_digit:

	; mouse wheel: cycle hotbar selection.  consumed once per
	; frame/uses sign of the accum only
	mov eax, [mouse_wheel_dy]
	test eax, eax
	jz .no_wheel
	mov dword [mouse_wheel_dy], 0
	push rax
	call inv_is_open
	pop rcx
	test eax, eax
	jnz .no_wheel				; inv up - inventory might want it later
	mov edi, ecx
	call hotbar_cycle
.no_wheel:

	; Q closes the inventory if open, else cancels placement mode
	cmp byte [key_close_pressed], 0
	je .no_close
	mov byte [key_close_pressed], 0
	call inv_is_open
	test eax, eax
	jz .close_try_place
	call inv_toggle 	; close inventory
	jmp .no_close
.close_try_place:
	call place_is_active
	test eax, eax
	jz .no_close
	call place_cancel
.no_close:

	; E key: gather/kill the tile or mob in front. eaten by inventory
	; (mouse-driven). also eaten in placement mode - placement is now
	; mouse-driven too so E shouldn't double up
	cmp byte [key_action_pressed], 0
	je .no_action
	mov byte [key_action_pressed], 0
	call inv_is_open
	test eax, eax
	jnz .no_action
	call place_is_active
	test eax, eax
	jnz .no_action
	call try_player_action
.no_action:

	; while the inventory screen is up, route mouse clicks to it
	; the world keeps ticking around the player; just suspend input
	call inv_is_open
	test eax, eax
	jz .no_inv_update
	call inv_update
	jmp .skip_place_clicks
.no_inv_update:
	; --- placement-mode mouse handling ---
	; left click: try to place on the tile under the mouse
	; right click: cancel placement entirely
	; only consume the click flags if place mode is on - otherwise
	; the events fall through and... currently nothing else uses them
	; but leaving them set is harmless
	call place_is_active
	test eax, eax
	jz .skip_place_clicks
	cmp byte [mouse_l_clicked], 0
	je .pm_no_left
	mov byte [mouse_l_clicked], 0
	call place_at_mouse
.pm_no_left:
	cmp byte [mouse_r_clicked], 0
	je .skip_place_clicks
	mov byte [mouse_r_clicked], 0
	call place_cancel
.skip_place_clicks:
	; --- player movement ---
	call update_player_input

	; mirror the player's position into entity[0] so the rest of the
	; entity systems (collision/future fight stuff) see it correctly
	call sync_player_to_entity

	; tick all non-player entities
	call entity_tick_all

	; resolve overlaps between entities (radial pushback)
	call entity_resolve_collisions

	; advance the tile-animation tick
	inc dword [tile_anim_ticks]

	; tree neighbour spread
	call tree_regrowth_tick

	; tick the floating text overlay (fade/lift)
	call floattext_tick

	; tick the status line fade
	call status_tick

	; clear any stale mouse-click flags - only consume when the
	; inventory is open. without this, opening the inv after some
	; clicks outside it replays them on the first frame
	call inv_is_open
	test eax, eax
	jnz .keep_mouse_flags
	mov byte [mouse_l_clicked], 0
	mov byte [mouse_r_clicked], 0
.keep_mouse_flags:

	; centre camera on player, clamped to world bounds
	call camera_update


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

	; object overlay - magenta-keyed sprites on top of the ground:
	; trees/doors/walls/bed etc.  drawn before entities so
	; the player/npcs render on top of furniture they're standing on
	lea rdi, [atlas_tex]
	call draw_objects

	; entities (player + NPCs, y-sorted)
	call draw_entities

	; placement-mode tile outline sits in world space
	; drawn between entities and HUD
	call place_draw_cursor

	; floating action text ("+1 wood" etc)
	call floattext_draw

	; bottom HUD bar
	call draw_hud_bar

	; hotbar strip just above the HUD bar.  drawn after the HUD
	; (so it overlaps cleanly) but before the inventory screen
	; (so opening the inv hides it - one place at a time)
	call draw_hotbar

	; inventory screen: drawn before console/status so the console can
	; still pop on top, but after the bottom HUD so it covers it
	call inv_draw

	; top-of-screen status line - always-on, fades out
	; (skipped internally if the console is open)
	; also skipped while inventory is open so the panel reads cleanly
	call inv_is_open
	test eax, eax
	jnz .skip_status_draw
	call status_draw
.skip_status_draw:
	; console panel last so it covers everything when open
	call console_draw

	; --- draw debug hud (if enabled & console isn't covering it) ---
	; also skipped while inventory is open
	cmp byte [console_open], 0
	jne .skip_hud_draw
	call inv_is_open
	test eax, eax
	jnz .skip_hud_draw
	call is_debug_hud_enabled
	test eax, eax
	jz .skip_hud_draw

	;top row: fps counter
	mov edi, 4 ; x
	mov esi, 14 ; y
	mov edx, 0xFFCCFFCC
	lea rcx, [hud_label_fps]
	mov r8d, [current_fps]
	call debug_print_label_int
	; iterations
	add eax, 8 ; bit of a gap between labels
	mov edi, eax
	mov esi, 14
	mov edx, 0xFF0033AA
	lea rcx, [hud_label_iters]
	mov r8d, [ca_iterations_count]
	call debug_print_label_int
	; seed
	add eax, 8 ; bit of a gap between labels
	mov edi, eax
	mov esi, 14
	mov edx, 0xFF000000
	lea rcx, [hud_label_seed]
	mov r8d, [current_seed]
	call debug_print_label_int

	; second line: help text
	mov edi, 4
	mov esi, 24
	mov edx, 0xFF000000;
	lea rcx, [hud_help]
	call debug_print

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
	lea rdi, [icons_tex]
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
	lea rdi, [icons_tex]
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
	lea rdi, [icons_tex]
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
	lea rdi, [icons_tex]
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
	lea rdi, [icons_tex]
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
	lea rdi, [icons_tex]
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
	cmp eax, SDL_TEXTINPUT_EVENT
	je .got_textinput
	cmp eax, SDL_MOUSEBUTTONDOWN
	je .got_mousedown
	cmp eax, SDL_MOUSEWHEEL_EVENT
	je .got_mousewheel
	jmp .poll

.got_quit:
	mov byte [key_quit], 1
	jmp .poll

.got_textinput:
	; SDL hands us already-shifted UTF-8 in event.text.text. when the
	; console isn't open this is harmless (handle_text checks first).
	lea rdi, [event_buf + SDL_EVENT_TEXT_OFF]
	call console_handle_text
	jmp .poll

.got_keydown:
	mov eax, [event_buf + SDL_EVENT_SCANCODE_OFF]
	cmp eax, SCANCODE_ESCAPE ;TMP - too easy to press w/ console open
	je .key_escape			 ;TMP
	; backtick toggles the console regardless of state, and matches
	; before anything else so it can close the console mid-typing
	cmp eax, SCANCODE_BACKTICK
	je .key_backtick
	; if console is open, route enter/backspace to it/eat everything
	; else (so movement/action keys don't fire while typing)
	cmp byte [console_open], 0
	je .console_closed_keys
	cmp eax, SCANCODE_RETURN
	je .key_return
	cmp eax, SCANCODE_BACKSPACE
	je .key_backspace
	jmp .poll
.console_closed_keys:
	cmp eax, SCANCODE_F3
	je .key_f3
	cmp eax, SCANCODE_F4
	je .key_f4
	cmp eax, SCANCODE_F5
	je .key_f5
	cmp eax, SCANCODE_E
	je .key_e
	cmp eax, SCANCODE_I
	je .key_i
	cmp eax, SCANCODE_Q
	je .key_q
	; SDL has SCANCODE_1..9 as 30..38 (contiguous), pick up the
	; whole range in one go and stash the digit (1..9) for the
	; main loop's hotbar handler to consume
	cmp eax, SCANCODE_1
	jl .poll
	cmp eax, SCANCODE_9
	jg .poll
	sub eax, SCANCODE_1 - 1		; 30 -> 1, 38 -> 9
	mov byte [key_hotbar_digit], al
	jmp .poll

.key_escape: ; TMP - too easy to press when console open
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
.key_e:
	mov byte [key_action_pressed], 1
	jmp .poll
.key_i:
	mov byte [key_inv_pressed], 1
	jmp .poll
.key_q:
	mov byte [key_close_pressed], 1
	jmp .poll
.key_backtick:
	call console_toggle
	jmp .poll
.key_return:
	call console_submit
	jmp .poll
.key_backspace:
	call console_backspace
	jmp .poll

.got_mousedown:
	; SDL_MouseButtonEvent has  button index at offset 16 (Uint8)
	; 1=left, 3=right. we ignore middle atm
	; set the matching one-shot flag for next time inv_update runs
	movzx eax, byte [event_buf + 16]
	cmp eax, SDL_BUTTON_LEFT
	je .mb_left
	cmp eax, SDL_BUTTON_RIGHT
	je .mb_right
	jmp .poll
.mb_left:
	mov byte [mouse_l_clicked], 1
	jmp .poll
.mb_right:
	mov byte [mouse_r_clicked], 1
	jmp .poll

.got_mousewheel:
	; SDL_MouseWheelEvent.y is at offset 20, Sint32.  positive
	; means wheel rolled up (away from user), negative is down
	; we accumulate so a fast spin doesn't lose ticks - the main
	; loop reads the sign and resets to 0
	mov eax, [event_buf + SDL_EVENT_WHEEL_Y_OFF]
	add [mouse_wheel_dy], eax
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
; camera_update: centre camera on player, clamped to world bounds
;----------------------------------------------------------------
; camera_x = clamp(player_x - WINDOW_W/2, 0, max_camera_x)
; max_camera_x = max(0, WORLD_PIXEL_W - WINDOW_W) - if the world
; is narrower than the window, we just stick the camera at 0
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

	; early return if console/inventory open
	cmp byte [console_open], 0
	jne .skip_movement
	cmp byte [inv_open], 0
	jne .skip_movement


	; -- left? (left arrow or A) --
	mov rax, [sdl_keystate]
	movzx ecx, byte [rax + SCANCODE_LEFT]
	movzx edx, byte [rax + SCANCODE_A]
	or ecx, edx
	test ecx, ecx
	jz .not_left
	mov dword [player_facing], FACE_LEFT
	mov edi, -move_step
	xor esi, esi
	call try_move
.not_left:
	; -- right? (right arrow or D) --
	mov rax, [sdl_keystate]
	movzx ecx, byte [rax + SCANCODE_RIGHT]
	movzx edx, byte [rax + SCANCODE_D]
	or ecx, edx
	test ecx, ecx
	jz .not_right
	mov dword [player_facing], FACE_RIGHT
	mov edi, move_step
	xor esi, esi
	call try_move
.not_right:
	; -- up? (up arrow or W) --
	mov rax, [sdl_keystate]
	movzx ecx, byte [rax + SCANCODE_UP]
	movzx edx, byte [rax + SCANCODE_W]
	or ecx, edx
	test ecx, ecx
	jz .not_up
	mov dword [player_facing], FACE_UP
	xor edi, edi
	mov esi, -move_step
	call try_move
.not_up:
	; -- down? (down arrow or S) --
	mov rax, [sdl_keystate]
	movzx ecx, byte [rax + SCANCODE_DOWN]
	movzx edx, byte [rax + SCANCODE_S]
	or ecx, edx
	test ecx, ecx
	jz .not_down
	mov dword [player_facing], FACE_DOWN
	xor edi, edi
	mov esi, move_step
	call try_move
.not_down:
.skip_movement:

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
; try_move: nudge the player by (dx, dy), checking collision
;----------------------------------------------------------------
; reads the destination tile's speed %:
; 0 blocks the move, 100 is full speed
; partial speeds (eg water at 50) accumulate across calls and apply 
; a step once the accumulator hits 100. should give nice slowing down
; without needing fractional pixel coords (ints only so far!)
;
; if blocked, the accumulator is cleared so a held direction against
; a wall doesn't build speed for when the wall ends
;----------------------------------------------------------------
; in: edi = dx, esi = dy
;================================================================
try_move:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	sub rsp, 8					; align

	mov ebx, edi				; dx
	mov r12d, esi				; dy

	; destination pixel = (player_x + dx, player_y + dy)
	mov edi, [player_x]
	add edi, ebx
	mov esi, [player_y]
	add esi, r12d

	call tile_speed_at_pixel	; eax = speed at dest
	test eax, eax
	jz .blocked

	add [move_accum], eax
	cmp dword [move_accum], 100
	jl .not_yet

	; accumulated enough - apply a full step
	sub dword [move_accum], 100
	add [player_x], ebx
	add [player_y], r12d
	mov byte [player_moved], 1

.not_yet:
	add rsp, 8
	pop r12
	pop rbx
	pop rbp
	ret

.blocked:
	mov dword [move_accum], 0 ;reset! see desc
	add rsp, 8
	pop r12
	pop rbx
	pop rbp
	ret
;================================================================
; player action (E key): act on the tile in front of player
;----------------------------------------------------------------
; alive npcs?: kill	  and give +1 gold
; tree/bush ?: remove and give +1 wood
; stone wall?: remove and give +1 stone
; else silent miss
;
; + fading hover text
;================================================================
try_player_action:
	push rbx
	push r12
	push r13
	push r14
	push r15
	; 5 callee-saves + ret = 48 bytes -> 16-aligned(!)

	; --- compute target tile (tx, ty) ---
	; player_x/y are pixel-centred on the player
	; div by TILE_SIZE to get current tile, then offset by facing
	mov eax, [player_x]
	mov ecx, TILE_SIZE
	cdq
	idiv ecx
	mov ebx, eax			; ebx = player_tx
	mov eax, [player_y]
	cdq
	idiv ecx
	mov r12d, eax			; r12d = player_ty

	mov eax, [player_facing]
	cmp eax, FACE_UP
	je .face_up
	cmp eax, FACE_LEFT
	je .face_left
	cmp eax, FACE_RIGHT
	je .face_right
	; default down
	inc r12d
	jmp .have_target
.face_up:
	dec r12d
	jmp .have_target
.face_left:
	dec ebx
	jmp .have_target
.face_right:
	inc ebx
.have_target:
	; ebx = target_tx, r12d = target_ty

	; bounds check - bail if outside the map!
	test ebx, ebx
	js .out
	cmp ebx, MAP_WIDTH
	jge .out
	test r12d, r12d
	js .out
	cmp r12d, MAP_HEIGHT
	jge .out

	; --- door toggle ---
	; if the target tile is a door, toggle open/closed and stop
	; trying it before the entity scan and the gather scan because
	; we do want E to be primarily "interact with the thing in
	; front" - and doors win over standing-on-grass-do-nothing
	mov edi, ebx
	mov esi, r12d
	call door_toggle_at
	test eax, eax
	jnz .out

	; --- look for npc entity in that tile ---
	; scan all alive non-player entities; first whose centre lies in
	; the target tile wins! tile bounds in pixels:
	;	x0 = tx*16, x1 = x0+16
	;	y0 = ty*16, y1 = y0+16
	; r15d = loop counter (callee-saved so it survives entity_ptr)
	mov r13d, ebx
	imul r13d, TILE_SIZE		; r13d = x0
	mov r14d, r12d
	imul r14d, TILE_SIZE		; r14d = y0

	xor r15d, r15d				; entity index
.scan:
	cmp r15d, [entity_count]
	jge .no_entity_hit

	mov edi, r15d
	call entity_ptr 			; rax = entity ptr

	; alive?
	movzx ecx, byte [rax + ENT_FLAGS_OFFSET]
	test ecx, ENT_FLAG_ALIVE
	jz .next_scan
	; non-player?
	movzx ecx, byte [rax + ENT_TYPE_OFFSET]
	cmp ecx, ENT_TYPE_PLAYER
	je .next_scan

	; tile-bounds test on the entity's centre
	mov ecx, [rax + ENT_X_OFFSET]
	cmp ecx, r13d
	jl .next_scan
	mov edi, r13d
	add edi, TILE_SIZE
	cmp ecx, edi
	jge .next_scan
	mov ecx, [rax + ENT_Y_OFFSET]
	cmp ecx, r14d
	jl .next_scan
	mov edi, r14d
	add edi, TILE_SIZE
	cmp ecx, edi
	jge .next_scan

	; hit! kill the entity (index in r15d) and grant +1 gold
	; TMP while there's no hp,damage etc, just a test
	mov edi, r15d
	call entity_kill
	inc word [player_res_gold]
	lea rdi, [floattext_gold]
	call spawn_floattext
	jmp .out

.next_scan:
	inc r15d
	jmp .scan

.no_entity_hit:
	; --- no entity; check the cell contents ---
	; objects take priority over ground - trees and stone walls
	; both live in the object overlay and are harvestable.  the
	; ground tile is left alone in either case
	mov edi, ebx
	mov esi, r12d
	call object_at
	cmp eax, OBJ_TREE
	je .got_tree
	cmp eax, OBJ_STONE_WALL
	je .got_stone

	; nothing harvestable - we're done
	jmp .out

.got_tree:
	; clear the tree from objectmap, ground stays untouched
	mov eax, r12d
	imul eax, MAP_WIDTH
	add eax, ebx
	lea rcx, [objectmap]
	mov byte [rcx + rax], OBJ_NONE
	inc word [player_res_wood]
	lea rdi, [floattext_wood]
	call spawn_floattext
	jmp .out

.got_stone:
	; chop the stone wall: ground becomes dirt, object slot clears
	mov eax, r12d
	imul eax, MAP_WIDTH
	add eax, ebx
	lea rdx, [objectmap]
	mov byte [rdx + rax], OBJ_NONE
	lea rdx, [tilemap]
	mov byte [rdx + rax], TILE_DIRT
	inc word [player_res_stone]
	lea rdi, [floattext_stone]
	call spawn_floattext

.out:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; floating text: "+1 wood" etc above the player
;----------------------------------------------------------------
; 1 slot total, new spawns replace old. lives FT_LIFETIME ticks
; lifts upwards by 1px every FT_LIFT_PERIOD ticks, linear "fade"
; TODO: experiment with colours, transparency
;================================================================
%define FT_LIFETIME		50
%define FT_LIFT_PERIOD	6
%define FT_MAX_TEXT		16

; spawn_floattext: copy a string into the slot, mark it active, place
; above the player.
; in: rdi = src null-terminated string ptr
spawn_floattext:
	; rdi = src (string ptr).  no calls inside, so no need to save it
	; position the text above the player's head
	mov eax, [player_x]
	mov [floattext_x], eax
	mov eax, [player_y]
	sub eax, 16 ; a tile above
	mov [floattext_y], eax
	mov word [floattext_ttl], FT_LIFETIME
	mov byte [floattext_active], 1
	; copy string into the buffer (up to FT_MAX_TEXT-1 bytes + null)
	mov rsi, rdi
	lea rdi, [floattext_buf]
	mov ecx, FT_MAX_TEXT - 1
.cp:
	test ecx, ecx
	jz .cp_done
	movzx eax, byte [rsi]
	mov [rdi], al
	test al, al
	jz .cp_done
	inc rsi
	inc rdi
	dec ecx
	jmp .cp
.cp_done:
	mov byte [rdi], 0
	ret

; floattext_tick: bookkeeping each frame: ttl--, lift y, expire
floattext_tick:
	cmp byte [floattext_active], 0
	je .out
	movzx eax, word [floattext_ttl]
	test eax, eax
	jz .expire
	dec eax
	mov word [floattext_ttl], ax
	; lift 1[x] per FT_LIFT_PERIOD ticks
	xor edx, edx
	mov ecx, FT_LIFT_PERIOD
	div ecx
	test edx, edx
	jnz .out
	dec dword [floattext_y]
	ret
.expire:
	mov byte [floattext_active], 0
.out:
	ret

; floattext_draw: render the string at camera (x,y)
; happens after the entities so it sits in front of everything
; fades to black atm
floattext_draw:
	cmp byte [floattext_active], 0
	je .out

	; intensity = ttl * 255 / FT_LIFETIME, 0..255
	movzx eax, word [floattext_ttl]
	imul eax, 255
	mov ecx, FT_LIFETIME
	xor edx, edx
	div ecx
	; eax = 0..255, modulate r,g,b channels of white by this:
	; feels a bit hacky, TEMP until i figure out how to blit alphas
	mov ecx, eax
	mov edx, eax
	shl edx, 8
	or ecx, edx
	mov edx, eax
	shl edx, 16
	or ecx, edx
	or ecx, 0xFF343434
	mov r9d, ecx	; r9d = colour

	; world -> screen
	mov edi, [floattext_x]
	sub edi, [camera_x]
	; nudge left a bit
	sub edi, 24 ; mb 14 is better?  this feels ok
	mov esi, [floattext_y]
	sub esi, [camera_y]
	mov edx, r9d
	lea rcx, [floattext_buf]
	call debug_print
.out:
	ret

section .data
	floattext_wood		db "+1 wood", 0
	floattext_stone		db "+1 stone", 0
	floattext_gold		db "+1 gold", 0

section .bss
	alignb 4
	floattext_active	resb 1
	floattext_ttl		resw 1
	floattext_x			resd 1
	floattext_y			resd 1
	floattext_buf		resb FT_MAX_TEXT

section .text

;================================================================
; restart_world: regenerate the world + reset player/entities
;----------------------------------------------------------------
; called from the F5 path and the /restart console command - so it
; needs a clean ret/don't fall through into anything else!
;================================================================
restart_world:
	push rbp
	mov rbp, rsp
	; restart pressed
	;call rng_seed_from_time
	call reset_world_iterations
	call rng_next
	mov eax, [rng_state]
	mov [current_seed], eax
	call generate_world
	call entity_clear_all
	; re-init player
	call place_player_on_floor
	mov byte [player_moved], 0
	; + reset NPCs
	call setup_world_entities
	; full reset wipes crafting grid, placement mode, & crafted-item
	; counts.  resources get re-init by setup_world_entities
	call inv_full_reset
	lea rdi, [log_msg_restart]
	call debug_log
	pop rbp
	ret


;================================================================
; update_mouse_state: cache mouse pos in logical (fb) px this frame
;----------------------------------------------------------------
; SDL gives us window-pixel coords, we div by current_scale to get
; the equivalent fb pixel
;
; SDL_GetMouseState(int* x, int* y) returns the button mask in eax.
; ignoring the return as the event flags give us easier click/hold
;================================================================
section .bss
	alignb 4
	mouse_win_x	resd 1
	mouse_win_y	resd 1
section .text

update_mouse_state:
	push rbp
	mov rbp, rsp
	lea rdi, [mouse_win_x]
	lea rsi, [mouse_win_y]
	call SDL_GetMouseState
	; logical x = window x / scale; same for y
	; shame we have to do a div, but it's once per frame, not per px,
	; and better than using an sdl call every frame
	mov eax, [mouse_win_x]
	cdq
	idiv dword [current_scale]
	mov [mouse_lx], eax
	mov eax, [mouse_win_y]
	cdq
	idiv dword [current_scale]
	mov [mouse_ly], eax
	pop rbp
	ret

;================================================================
; place_player_on_floor: random non-stone tile
;================================================================
place_player_on_floor:
	push rbx
	push r12
	mov r12d, 200
.try:
	test r12d, r12d
	jz .scan
	dec r12d

	mov edi, MAP_WIDTH
	call rng_range
	mov ebx, eax	; tx

	mov edi, MAP_HEIGHT
	call rng_range
	mov ecx, eax	; ty

	imul ecx, MAP_WIDTH
	add ecx, ebx
	lea rdx, [tilemap]
	movzx eax, byte [rdx + rcx]
	; reject tiles < 100% movespeed
	lea rdx, [tile_speed_table]
	movzx eax, byte [rdx + rax]
	cmp eax, 100
	jne .try

	imul ebx, TILE_SIZE
	add ebx, TILE_SIZE/2
	mov [player_x], ebx
	mov eax, ecx
	xor edx, edx
	mov ecx, MAP_WIDTH
	div ecx
	imul eax, TILE_SIZE
	add eax, TILE_SIZE/2
	mov [player_y], eax

	pop r12
	pop rbx
	ret

.scan:
	xor ecx, ecx
.scan_loop:
	cmp ecx, MAP_WIDTH * MAP_HEIGHT
	jge .scan_fail
	lea rdx, [tilemap]
	movzx eax, byte [rdx + rcx]
	lea rdx, [tile_speed_table]
	movzx eax, byte [rdx + rax]
	cmp eax, 100
	je .scan_found
	inc ecx
	jmp .scan_loop
.scan_found:
	mov eax, ecx
	xor edx, edx
	mov ecx, MAP_WIDTH
	div ecx
	imul edx, TILE_SIZE
	add edx, TILE_SIZE/2
	mov [player_x], edx
	imul eax, TILE_SIZE
	add eax, TILE_SIZE/2
	mov [player_y], eax
.scan_fail:
	pop r12
	pop rbx
	ret

;================================================================
; sync_player_to_entity: copy player_* into entity[0] before draw
;----------------------------------------------------------------
; we keep player_* as the source of truth for input handling and HUD,
; the entity table mirrors it so it gets y-sorted with everyone else
;================================================================
sync_player_to_entity:
	xor edi, edi
	call entity_ptr 	; rax = &entity[0]
	mov edi, [player_x]
	mov [rax + ENT_X_OFFSET], edi
	mov edi, [player_y]
	mov [rax + ENT_Y_OFFSET], edi
	mov edi, [player_facing]
	mov byte [rax + ENT_FACING_OFFSET], dil
	mov edi, [player_anim_phase]
	mov byte [rax + ENT_PHASE_OFFSET], dil
	ret

;================================================================
; setup_world_entities: wipe + repopulate after a world regen
;================================================================
setup_world_entities:
	push rbx
	push r12
	push r14
	push r15
	; 4 pushes = 32 bytes = 16-aligned; return addr handled by call
	call entity_clear_all

	; spawn player at i=0, w/ existing x/y from place_player_on_floor
	; and default down facing
	mov edi, ENT_TYPE_PLAYER
	mov esi, [player_x]
	mov edx, [player_y]
	mov ecx, 0 			; sprite slot 0 (down-facing)
	call entity_spawn

	; reset player anim/facing state - new world, fresh start
	mov dword [player_facing], FACE_DOWN
	mov dword [player_anim_phase], 0
	mov dword [player_anim_timer], 0
	mov dword [move_accum], 0

	; init player stats + inventory
	mov word [player_hp_max], 10
	mov word [player_hp], 10
	mov word [player_res_wood], 3
	mov word [player_res_stone], 1
	mov word [player_res_food], 5
	mov word [player_res_gold], 0

	; ebx = stubs spawned, r12d = attempts so far
	; attempts are capped just in case
	mov ebx, 0
	mov r12d, 0
.stub_loop:
	cmp ebx, 30
	jge .stubs_done
	cmp r12d, 400
	jge .stubs_done

	inc r12d

	; px = player_x + (rand[-15..15]) * TILE
	mov edi, 31
	call rng_range
	sub eax, 15
	imul eax, TILE_SIZE
	add eax, [player_x]
	mov r14d, eax			; r14 = candidate x

	mov edi, 31
	call rng_range
	sub eax, 15
	imul eax, TILE_SIZE
	add eax, [player_y]
	mov r15d, eax			; r15 = candidate y

	; reject if not walkable
	mov edi, r14d
	mov esi, r15d
	call tile_speed_at_pixel
	cmp eax, 100
	jne .stub_loop

	; pick type/slot: 2/3 heroes, 1/3 monsters. roll 0..2
	mov edi, 3
	call rng_range
	test eax, eax
	jz .spawn_monster
	; hero
	mov edi, ENT_TYPE_HERO
	mov esi, r14d
	mov edx, r15d
	mov ecx, 4				; hero base slot
	call entity_spawn
	jmp .check_spawn
.spawn_monster:
	mov edi, ENT_TYPE_MONSTER
	mov esi, r14d
	mov edx, r15d
	mov ecx, 8				; monster base slot
	call entity_spawn
.check_spawn:
	test eax, eax
	js .stubs_done			; table full
	inc ebx
	jmp .stub_loop
.stubs_done:
	pop r15
	pop r14
	pop r12
	pop rbx
	ret

;================================================================
; draw_entities: y-sort the entity table and blit each alive entity
;
; sprite slot pick (4-frame layout: 0 d, 1 u, 2 left-A, 3 left-B):
;
; pose selection only applies to PLAYER atm::
;	facing DOWN		-> slot 0, flip alternates with phase
;	facing UP		-> slot 1, flip alternates with phase
;	facing LEFT		-> slot 2 or 3 by phase, no flip
;	facing RIGHT	-> slot 2 or 3 by phase, flipped
;
; TEMP npcs just blit sprite directly
;================================================================
draw_entities:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	push r13
	push r14
	push r15
	sub rsp, 8						; align

	call entity_sort_draw_order

	mov r14d, [entity_count]
	xor r15d, r15d					; loop index
.next:
	cmp r15d, r14d
	jge .done

	lea rax, [entity_draw_order]
	movzx ebx, byte [rax + r15]		; ebx = entity index

	mov edi, ebx
	call entity_ptr
	mov r13, rax					; r13 = entity ptr

	; skip dead
	movzx eax, byte [r13 + ENT_FLAGS_OFFSET]
	test eax, ENT_FLAG_ALIVE
	jz .skip

	; pose pick - works for any entity using the 4-frame layout
	; (down, up, left-A, left-B). the entity's sprite_slot field is
	; the *base* slot of its 4-frame block in the sprite sheet
	;	facing DOWN  -> base+0, flip alternates with phase
	;	facing UP	 -> base+1, flip alternates with phase
	;	facing LEFT  -> base+2 or base+3 by phase, no flip
	;	facing RIGHT -> base+2 or base+3 by phase, flipped
	; very TEMP
	movzx r12d, byte [r13 + ENT_SLOT_OFFSET]	; r12 = base slot
	movzx eax, byte [r13 + ENT_FACING_OFFSET]
	cmp eax, FACE_DOWN
	je .pp_down
	cmp eax, FACE_UP
	je .pp_up
	cmp eax, FACE_LEFT
	je .pp_left
	; right
	add r12d, 2
	movzx edx, byte [r13 + ENT_PHASE_OFFSET]
	add r12d, edx
	mov ecx, 1
	jmp .pose_done
.pp_left:
	add r12d, 2
	movzx edx, byte [r13 + ENT_PHASE_OFFSET]
	add r12d, edx
	xor ecx, ecx
	jmp .pose_done
.pp_down:
	; base+0, flip on phase 1
	movzx ecx, byte [r13 + ENT_PHASE_OFFSET]
	jmp .pose_done
.pp_up:
	add r12d, 1
	movzx ecx, byte [r13 + ENT_PHASE_OFFSET]
.pose_done:

	; now blit! r12d already holds slot, ecx holds flip
	; we use callee-saved regs to hold dst_x, dst_y

	push rcx					; flip onto stack briefly
	mov eax, [r13 + ENT_X_OFFSET]
	sub eax, [camera_x]
	sub eax, SPRITE_SIZE/2
	mov ebx, eax				; ebx = dst_x

	mov eax, [r13 + ENT_Y_OFFSET]
	sub eax, [camera_y]
	sub eax, SPRITE_SIZE/2
	; dst_y goes straight into a stack slot below

	; build call args. blit_texture_rect_keyed signature:
	; rdi=tex, esi=src_x, edx=src_y, ecx=src_w, r8d=src_h, r9d=dst_x
	;[rbp+16]=dst_y,[rbp+24]=flip,[rbp+32]=key-> push key/flip/dst_y
	pop rdi			; dil = flip we saved
	movzx edi, dil	; clean upper bits

	; push args right-to-left: key first
	; we need 16-byte rsp alignment at the call: 3 pushes = 24 bytes
	; would leave us misaligned,so drop an extra 8 bytes first
	sub rsp, 8					; alignment pad
	mov rcx, SPRITE_COLOR_KEY
	push rcx					; key
	push rdi					; flip
	cdqe			; dst_y is in eax; sign-extend to rax for push
	push rax					; dst_y

	lea rdi, [sprites_tex]
	mov esi, r12d
	imul esi, SPRITE_SIZE		; src_x
	xor edx, edx				; src_y = 0
	mov ecx, SPRITE_SIZE		; src_w
	mov r8d, SPRITE_SIZE		; src_h
	mov r9d, ebx				; dst_x

	call blit_texture_rect_keyed
	add rsp, 32					; 24 args + 8 pad

.skip:
	inc r15d
	jmp .next
.done:
	add rsp, 8
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret
