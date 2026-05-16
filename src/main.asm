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
%include "ai.inc.asm"
%include "shadow.inc.asm"
%include "entity_player.inc.asm"
%include "daynight.inc.asm"
%include "worldgen.inc.asm"
%include "debug.inc.asm"
%include "console.inc.asm"
%include "inventory.inc.asm"
%include "hud.inc.asm"
%include "camera.inc.asm"
%include "fps.inc.asm"
%include "safezone.inc.asm"
%include "pathing.inc.asm"
%include "bloodmap.inc.asm"
%include "spawn.inc.asm"
%include "input.inc.asm"

section .data
	window_title		db "Town Assembly", 0
	tile_ppm_file		db "res/tiles.ppm", 0
	sprites_ppm_file	db "res/sprites.ppm", 0
	icons_ppm_file		db "res/icons.ppm", 0
	scale_quality_hint	db "SDL_RENDER_SCALE_QUALITY", 0
	scale_quality_value	db "0", 0	; "0" = nearest-neighbour

	; SDL error messages.  10 = \n, 0 = C-style terminator
	err_init_msg		db "SDL_Init failed", 10, 0
	err_window_msg		db "SDL_CreateWindow failed", 10, 0
	err_renderer_msg	db "SDL_CreateRenderer failed", 10, 0
	err_texture_msg		db "SDL_CreateTexture failed", 10, 0
	err_ppm_msg			db "load_ppm failed", 10, 0

	; HUD text
	hud_label_fps		db "fps", 0
	hud_label_iters		db "iters", 0
	hud_label_seed		db "seed", 0
	hud_help			db "` console F3 hud F5 restart F6 safezone F7 flowmap i inv 1-5 hotbar", 0

	; log messages
	log_msg_started		db 0x1, " world generated! ", 0x3, 0
	log_msg_restart		db "regenerated world", 0

section .bss
	alignb 8
	sdl_window			resq 1
	sdl_renderer 		resq 1
	sdl_texture			resq 1
	sdl_keystate		resq 1
	current_scale		resq 1

	alignb 4
	current_seed		resd 1	; stash for HUD

	; mouse cache - SDL gives us window-pixel coords, we div by
	; current_scale once per frame to get the fb-pixel coord that
	; the rest of the UI hit-tests against
	alignb 4
	mouse_win_x			resd 1
	mouse_win_y			resd 1

section .text

main:
	push rbp	; align stack to 16, "frame pointer" convention
	mov rbp, rsp	; tell debugger where the frame is

	; load tile atlas - tiles.ppm.  must be 16x16 px tiles, matching
	; tile types in tilemap.inc.asm
	lea rdi, [atlas_tex]
	lea rsi, [tile_ppm_file]
	call load_ppm_texture
	test eax, eax
	jnz .fail_ppm

	; load sprite sheet - sprites.ppm
	; layout: row of 16x16 sprites, slot 0..N, magenta = transparent
	; expected slots atm:
	; 0=down|1=up|2=left-A|3=left-B then heroes/monsters
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
	mov [current_seed], eax		; store for HUD
	call generate_world

	; hub is the carved 3x3 at map centre - init it before placing
	; the player so the player can spawn there directly
	call pathing_init_default_hub

	; player init - spawn at the hub.  place_player_on_floor is kept
	; around for fallback use (eg if we later want random starts)
	;call place_player_on_floor
	call place_player_at_hub
	mov byte [player_moved], 0
	call setup_world_entities	; place NPCs
	call inv_init				; set up inventory
	call daynight_reset
	call safezone_recompute		; initial mask
	call pathing_recompute		; flow field from the hub outward
	call blood_init				; one-time setup of the blood_fb
								; tex_struct.  must happen before
								; any splat or any blood_clear
	call blood_clear			; no blood on a fresh world
	call spawn_reset

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

	; create gpu streaming texture we'll upload to each frame.
	; STREAMING (not STATIC/TARGET) tells SDL we'll be uploading
	; new pixels often
	mov rdi, [sdl_renderer]
	mov esi, SDL_PIXELFORMAT_ARGB8888
	mov edx, SDL_TEXTUREACCESS_STREAMING
	mov ecx, WINDOW_W
	mov r8d, WINDOW_H
	call SDL_CreateTexture
	test rax, rax
	jz .fail_texture
	mov [sdl_texture], rax

	call fps_init

	; --- main loop ---
.main_loop:
	call process_sdl_events

	cmp byte [key_quit], 0
	jne .cleanup

	; mirror OS-level mouse position into our logical pixel coords
	; once per frame, so any UI hit-tests this frame are consistent
	call update_mouse_state

	; consume one-shot key flags + mouse wheel
	call dispatch_input

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
	; the events fall through and... currently nothing else uses
	; them but leaving them set is harmless
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

	; pull entity[0] back into player_* - mirrors any AI damage dealt
	; this frame.  if we died, this triggers respawn at the hub
	call sync_entity_to_player

	; resolve overlaps between entities (radial pushback)
	call entity_resolve_collisions

	; advance the tile-animation tick
	inc dword [tile_anim_ticks]

	; tree neighbour spread
	call tree_regrowth_tick

	; monster spawning - one attempt every SPAWN_TICK_PERIOD frames
	; in dark tiles, capped at MONSTER_CAP alive
	call spawn_tick

	; advance the day/night clock
	call daynight_tick

	; tick the floating text overlay (fade/lift)
	call floattext_tick

	; tick the status line fade
	call status_tick

	; advance bloodmap for fading (usually does nothing)
	call blood_age_tick

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

	; --- render ---
	lea rdi, [atlas_tex]
	call draw_tilemap 

	; object overlay - magenta-keyed sprites on top of the ground:
	; trees/doors/walls/bed etc.  drawn before entities so
	; the player/npcs render on top of furniture they're standing on
	lea rdi, [atlas_tex]
	call draw_objects

	; blood splatters between objects and entities so blood sits on
	; the ground/objects but underneath any entity standing on it
	lea rdi, [atlas_tex]
	call blood_draw_all

	; entities (player + NPCs, y-sorted)
	call draw_entities

	; placement-mode tile outline sits in world space
	; drawn between entities and HUD
	call place_draw_cursor

	; floating action text ("+1 wood" etc)
	call floattext_draw

	; day/night
	call daynight_apply_tint
	call daynight_draw_all_torches

	; safezone debug overlay (F6) - tints dark tiles.  drawn after
	; daynight so it reads correctly against any tinted world, but
	; before HUD so it doesn't bleed under the UI
	call safezone_draw_debug

	; flow-field debug overlay (F7) - per-tile arrow toward hub +
	; a marker on the hub itself.  same placement reasoning
	call pathing_draw_debug

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

.skip_hud_draw:

	; bump frame_count, maybe re-sample FPS
	call fps_tick

	; upload framebuffer to gpu texture
	mov rdi, [sdl_texture]
	xor rsi, rsi				; NULL - whole texture
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
	; could be either atlas/sprites/icons that failed.  free_texture
	; is null-safe so an uninit struct is fine
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
; restart_world: regenerate world + reset player/entities
;----------------------------------------------------------------
; called from F5 and the /restart console command - clean ret,
; don't fall through into anything else
;================================================================
restart_world:
	push rbp
	mov rbp, rsp
	;call rng_seed_from_time
	call reset_world_iterations
	call rng_next
	mov eax, [rng_state]
	mov [current_seed], eax
	call generate_world
	call entity_clear_all
	; hub init must happen before placing the player so we can spawn
	; them on it.  place_player_on_floor is kept around for fallback
	call pathing_init_default_hub
	call place_player_at_hub
	mov byte [player_moved], 0
	; + reset NPCs
	call setup_world_entities
	; full reset wipes crafting grid, placement mode, & crafted-item
	; counts.  resources get re-init by setup_world_entities
	call inv_full_reset
	call daynight_reset
	call safezone_recompute		; mask is fresh after regen
	call pathing_recompute
	call blood_clear
	call spawn_reset
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
