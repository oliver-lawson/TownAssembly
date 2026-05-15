; inventory.inc.asm - inventory screen/crafting grid/placement mode
;
; one big module because these are tightly coupled:
; inventory UI is the host for the crafting grid, the result of
; crafting is items that go into inventory which then drive placement
;
; --- player items ---
;
; resources (gathered) live in player_res_* (main.asm) atm
; "crafted item" inventory tracks things like wood walls, floors,
; doors etc. - placeable tiles that the player carries around.. TMP
;
; inv_item_count[ITEM_*] = u16
;
; --- crafting grid ---
;
; 3x3 grid plus a 1x1 result slot
; each grid cell holds an "ingredient ; id" - same enumeration as 
; gather resources(wood,stone etc) value
; INGRED_NONE means empty. the result slot is updated whenever the
; grid changes - we walk the recipe table looking for a pattern match
;
; --- recipe matching ---
;
; recipes are stored as a flat 9-byte pattern + 1 result item id
;slot 0..8 of the pattern correspond to grid cell (x+y*3) of the grid
; (ie pattern[0] is top-left, pattern[8] is bottom-right)
;slot=INGRED_NONE means "must be empty in the grid".  this lets us
;distinguish "wood floor needs hollow centre" from a 3x3 of wood etc

%ifndef INVENTORY_INC
%define INVENTORY_INC

;-- ingredient ids:shared with the gather resources --
%define INGRED_NONE		0
%define INGRED_WOOD		1
%define INGRED_STONE	2
%define INGRED_FOOD		3
%define INGRED_GOLD		4
%define INGRED_COUNT	5

; --- placeable item ids (everything craftanble) ---
%define ITEM_NONE		0
%define ITEM_WOOD_FLOOR	1
%define ITEM_WOOD_WALL	2
%define ITEM_WOOD_DOOR	3
%define ITEM_BED		4
%define ITEM_CHAIR		5
%define ITEM_TORCH		6
%define ITEM_COUNT		7

; --- recipes ---
; recipe row layout: 9 pattern bytes + 1 result byte = 10 bytes
; recipes ordered by output id
; NB add a new row + bump RECIPE_COUNT to extend
%define RECIPE_STRIDE	10
%define RECIPE_COUNT	9

; -- crafting grid + result slot --
%define GRID_W 3
%define GRID_H 3
%define GRID_CELLS (GRID_W * GRID_H)

; -- UI layout (in framebuffer pixels) --
; the panel is centred in the framebuffer and covers most of it, but
;leaves a margin so the world is dimly visible behind.all subordinate
; widgets (resources column, grid, result) are placed relative to the
; panel origin
%define INV_PANEL_X		24
%define INV_PANEL_Y		16
%define INV_PANEL_W		(WINDOW_W -INV_PANEL_X*2)
%define INV_PANEL_H		(WINDOW_H -INV_PANEL_Y*2 -16) ;leave HUD room
%define INV_PANEL_BG	0xF0080812
%define INV_PANEL_BORDER 0xFF8090A0
%define INV_PANEL_TEXT	0xFFFFFFFF
%define INV_TITLE_TEXT	0xFFFFFFC0
%define INV_DIM_TEXT	0xFFB0B0C0

; resources column on left of the panel
%define INV_RES_X		(INV_PANEL_X + 8)
%define INV_RES_Y		(INV_PANEL_Y + 30)
%define INV_RES_PITCH	14	; px between resource rows
%define INV_RES_SLOT_W	78	; clickable slot width (full label)
%define INV_RES_SLOT_H  10	; clickable slot height

; 3x3 crafting grid in the middle
%define INV_GRID_CELL	18	; cell width/height in px
%define INV_GRID_GAP	2
%define INV_GRID_X		(INV_PANEL_X + 100)
%define INV_GRID_Y		(INV_PANEL_Y + 30)
%define INV_GRID_W_PX  (GRID_W*INV_GRID_CELL+(GRID_W-1)*INV_GRID_GAP)
%define INV_GRID_H_PX  (GRID_H*INV_GRID_CELL+(GRID_H-1)*INV_GRID_GAP)

; result slot to the right of the grid (with arrow gap)
%define INV_RESULT_X	(INV_GRID_X + INV_GRID_W_PX + 24)
%define INV_RESULT_Y	(INV_GRID_Y + INV_GRID_CELL + INV_GRID_GAP)
%define INV_RESULT_W	INV_GRID_CELL
%define INV_RESULT_H	INV_GRID_CELL

; clear-grid button - small square below the result slot. refunds
; everything in the grid and zeroes it
%define INV_CLEAR_X		INV_RESULT_X
%define INV_CLEAR_Y		(INV_RESULT_Y + INV_RESULT_H + 6)
%define INV_CLEAR_W		INV_RESULT_W
%define INV_CLEAR_H		INV_RESULT_H

; placeable items list along the bottom of the panel
; we draw INV_ITEMS_SLOTS empty boxes regardless of how many real item
; types exist - everything past ITEM_COUNT-1 just stays empty
%define INV_ITEMS_SLOTS	8
%define INV_ITEMS_X		(INV_PANEL_X + 8)
%define INV_ITEMS_Y		(INV_PANEL_Y + INV_PANEL_H - 28)
%define INV_ITEMS_PITCH 22
%define INV_ITEMS_SLOT_W 20
%define INV_ITEMS_SLOT_H 20

section .data
	; recipes (pattern[9] + result) w INGRED_* for patterns
	;
	; pattern indexing matches grid cell (col + row*3).
	recipe_table:
		; wood floor:
		;	www
		;	w.w
		;	www
		db INGRED_WOOD, INGRED_WOOD, INGRED_WOOD
		db INGRED_WOOD, INGRED_NONE, INGRED_WOOD
		db INGRED_WOOD, INGRED_WOOD, INGRED_WOOD
		db ITEM_WOOD_FLOOR

		; wood wall:
		;	sss
		;	www
		;	www
		db INGRED_STONE, INGRED_STONE, INGRED_STONE
		db INGRED_WOOD,  INGRED_WOOD,  INGRED_WOOD
		db INGRED_WOOD,  INGRED_WOOD,  INGRED_WOOD
		db ITEM_WOOD_WALL

		; wood door:
		;	sss
		;	www
		;	sss
		db INGRED_STONE, INGRED_STONE, INGRED_STONE
		db INGRED_WOOD,  INGRED_WOOD,  INGRED_WOOD
		db INGRED_STONE, INGRED_STONE, INGRED_STONE
		db ITEM_WOOD_DOOR

		; bed - food for blanket for now...
		;	fff
		;	www
		;	www
		db INGRED_FOOD,  INGRED_FOOD,  INGRED_FOOD
		db INGRED_WOOD,  INGRED_WOOD,  INGRED_WOOD
		db INGRED_WOOD,  INGRED_WOOD,  INGRED_WOOD
		db ITEM_BED

		; chair
		;	w.w
		;	www
		;	w.w
		db INGRED_WOOD,  INGRED_NONE,  INGRED_WOOD
		db INGRED_WOOD,  INGRED_WOOD,  INGRED_WOOD
		db INGRED_WOOD,  INGRED_NONE,  INGRED_WOOD
		db ITEM_CHAIR
		
		; torch:
		;	.f.
		;	.w.
		;	...
		db INGRED_NONE, INGRED_FOOD, INGRED_NONE
		db INGRED_NONE, INGRED_WOOD, INGRED_NONE
		db INGRED_NONE, INGRED_NONE, INGRED_NONE
		db ITEM_TORCH

		; easy recipes for debugging:
		db INGRED_WOOD, INGRED_NONE, INGRED_NONE
		db INGRED_NONE, INGRED_NONE, INGRED_NONE
		db INGRED_NONE, INGRED_NONE, INGRED_NONE
		db ITEM_WOOD_WALL
		
		db INGRED_STONE,INGRED_NONE, INGRED_NONE
		db INGRED_NONE, INGRED_NONE, INGRED_NONE
		db INGRED_NONE, INGRED_NONE, INGRED_NONE
		db ITEM_WOOD_FLOOR
		
		db INGRED_GOLD, INGRED_NONE, INGRED_NONE
		db INGRED_NONE, INGRED_NONE, INGRED_NONE
		db INGRED_NONE, INGRED_NONE, INGRED_NONE
		db ITEM_WOOD_DOOR


	; ui labels for resources + items
	inv_title_str		db "INVENTORY", 0
	inv_label_resources	db "Resources", 0
	inv_label_grid		db "Crafting", 0
	inv_label_result	db "->", 0
	inv_label_items		db "Items", 0
	inv_label_clear		db "X", 0

	inv_res_name_wood	db "Wood", 0
	inv_res_name_stone	db "Stone", 0
	inv_res_name_food	db "Food", 0
	inv_res_name_gold	db "Gold", 0

	inv_item_name_floor	db "Wood Floor", 0
	inv_item_name_wall	db "Wood Wall", 0
	inv_item_name_door	db "Wood Door", 0
	inv_item_name_bed	db "Bed", 0
	inv_item_name_chair	db "Chair", 0
	inv_item_name_torch	db "Torch", 0

	; ingredient -> background tint drawn under the icon in crafting
	; cells/cursor (icons are opaque art so this only shows around the
	; edges, but it gives a hint of colour-coding when the cell is hovered)
	align 4
	ingred_swatch_colour:
		dd 0x00000000	; INGRED_NONE - never drawn
		dd 0xFFB07840	; wood
		dd 0xFFA0A0A8	; stone
		dd 0xFF60D050	; food
		dd 0xFFE0C040	; gold

	; ingredient id -> icons_tex slot. icons_tex has heart at 0 and the
	; resource icons at slots 1..4 - same enumeration as INGRED_*
	; so this is effectively the identity, but keeping it explicit
	; means we can rearrange icons.ppm without touching INGRED_*
	ingred_icon_slot:
		db 0	; none - never drawn
		db 1	; wood
		db 2	; stone
		db 3	; food
		db 4	; gold

	; placeable items -> the tile id they put in the world
	; lookup table.  doors get their orientation picked at place
	; time, so we resolve to the "ns closed" variant here and the
	; placement code may swap to ew if the neighbours suggest it
	align 4
	item_tile_id:
		db 0	; none
		db TILE_WOOD_FLOOR
		db TILE_WOOD_WALL
		db TILE_WOOD_DOOR_EW_C
		db TILE_BED
		db TILE_CHAIR
		db TILE_TORCH

	; on-fail floattext for placement mode
	inv_msg_blocked		db "blocked", 0

section .bss
	alignb 4
	inv_open	resb 1	; 1 if the inventory screen is showing
	; cursor: which ingredient (INGRED_*) and how many of it. zero
	; ingred means "empty cursor" regardless of count. picking up from
	; a resource slot grabs the whole stack at once
	inv_cursor_ingred	resb 1
	alignb 2
	inv_cursor_count	resw 1
	; mouse state mirrored to logical-pixel coords each frame
	alignb 4
	mouse_lx	resd 1
	mouse_ly	resd 1
	; one-shot left/right click flags (raised by pump_events)
	mouse_l_clicked	resb 1
	mouse_r_clicked	resb 1

	; crafting grid - 9 cells of ingredient ids
	alignb 4
	craft_grid	resb GRID_CELLS
	; result slot:
	; ITEM_NONE if no match, else the item id that would be produced
	craft_result	resb 1

	; placeable item counts. inv_item_count[ITEM_*] = u16.
	alignb 2
	inv_item_count resw ITEM_COUNT

	; placement mode state. when active, normal player movement still
	; works but E key places the selected item in the tile in front
	; instead of gathering
	alignb 4
	place_mode	resb 1	; 1 if active
	place_item	resb 1	; ITEM_* currently selected

	; -- hotbar state --
	; per item shows (1..ITEM_COUNT-1). hotbar_selected is the
	; item id currently highlighted; ITEM_NONE means nothing selected
	; and nothing happens. selecting flips into placement mode for
	; that item (provided we have at least one)
	hotbar_selected	resb 1
	; one-shot mouse wheel delta accumulated by event polling
	; positive = scroll up, negative = scroll down. the per-frame
	; consumer reads it and zeros it
	alignb 4
	mouse_wheel_dy	resd 1

section .text

;================================================================
; inv_init: zero the bss-side state (called @ startup & world regen)
;================================================================
inv_init:
	mov byte [inv_open], 0
	mov byte [inv_cursor_ingred], INGRED_NONE
	mov word [inv_cursor_count], 0
	mov byte [craft_result], ITEM_NONE
	mov byte [place_mode], 0
	mov byte [place_item], ITEM_NONE
	mov byte [hotbar_selected], ITEM_NONE
	mov dword [mouse_wheel_dy], 0
	mov byte [mouse_l_clicked], 0
	mov byte [mouse_r_clicked], 0
	; clear the crafting grid
	push rdi
	push rcx
	push rax
	lea rdi, [craft_grid]
	mov ecx, GRID_CELLS
	xor eax, eax
	rep stosb
	pop rax
	pop rcx
	pop rdi
	ret

;================================================================
; inv_full_reset: stronger reset - also wipes crafted items
;----------------------------------------------------------------
; not called on world F5 for now for demoing sake
;================================================================
inv_full_reset:
	call inv_init
	; zero placeable item counts (size = ITEM_COUNT * 2 bytes)
	push rdi
	push rcx
	push rax
	lea rdi, [inv_item_count]
	mov ecx, ITEM_COUNT
	xor eax, eax
	rep stosw
	pop rax
	pop rcx
	pop rdi
	ret

;================================================================
; inv_is_open: returns 1 if inventory screen is up
;----------------------------------------------------------------
; main.asm uses this to suspend world-tick of the player (NPCs etc
; keep ticking) and to route input
;================================================================
inv_is_open:
	movzx eax, byte [inv_open]
	ret

;================================================================
; inv_toggle: open <-> close the inventory
;----------------------------------------------------------------
; on close, also drops whatever's on the cursor back into resources
;================================================================
inv_toggle:
	mov al, [inv_open]
	xor al, 1
	mov [inv_open], al
	test al, al
	jnz .opened
.closed:
	; closing: refund whatever's on the cursor. otherwise repeatedly
	; opening/closing while holding a stack would leak resources
	call inv_drop_cursor
	ret
.opened:
	; entering:cursor starts empty, recompute result in case the grid
	; was left non-empty from a previous session
	mov byte [inv_cursor_ingred], INGRED_NONE
	mov word [inv_cursor_count], 0
	call craft_recompute_result
	ret

;================================================================
; inv_refund_ingredient
;----------------------------------------------------------------
; inc the player's resource num for the ingredient id in al
; used when we cancel a held cursor item.
;================================================================
inv_refund_ingredient:
	cmp al, INGRED_WOOD
	je .refund_wood
	cmp al, INGRED_STONE
	je .refund_stone
	cmp al, INGRED_FOOD
	je .refund_food
	cmp al, INGRED_GOLD
	je .refund_gold
	ret
.refund_wood:
	inc word [player_res_wood]
	ret
.refund_stone:
	inc word [player_res_stone]
	ret
.refund_food:
	inc word [player_res_food]
	ret
.refund_gold:
	inc word [player_res_gold]
	ret

;================================================================
; inv_refund_ingredient_n
;----------------------------------------------------------------
; add cx to the player's resource for ingredient id in al
; in:  al = INGRED_*, cx = count to add
;================================================================
inv_refund_ingredient_n:
	test cx, cx
	jz .out
	cmp al, INGRED_WOOD
	je .nw
	cmp al, INGRED_STONE
	je .ns
	cmp al, INGRED_FOOD
	je .nf
	cmp al, INGRED_GOLD
	je .ng
	ret
.nw:
	add [player_res_wood], cx
	ret
.ns:
	add [player_res_stone], cx
	ret
.nf:
	add [player_res_food], cx
	ret
.ng:
	add [player_res_gold], cx
.out:
	ret

;================================================================
; inv_drop_cursor: refund whatever the cursor is holding back into
; resources and empty it. no-op if the cursor is already empty
;================================================================
inv_drop_cursor:
	movzx eax, byte [inv_cursor_ingred]
	test eax, eax
	jz .out
	movzx ecx, word [inv_cursor_count]
	call inv_refund_ingredient_n
	mov byte [inv_cursor_ingred], INGRED_NONE
	mov word [inv_cursor_count], 0
.out:
	ret

;================================================================
; inv_get_resource_count: return the player's count of ingredient al
;----------------------------------------------------------------
; out: eax = count (or 0 for INGRED_NONE)
;================================================================
inv_get_resource_count:
	cmp al, INGRED_WOOD
	je .grc_wood
	cmp al, INGRED_STONE
	je .grc_stone
	cmp al, INGRED_FOOD
	je .grc_food
	cmp al, INGRED_GOLD
	je .grc_gold
	xor eax, eax
	ret
.grc_wood:
	movzx eax, word [player_res_wood]
	ret
.grc_stone:
	movzx eax, word [player_res_stone]
	ret
.grc_food:
	movzx eax, word [player_res_food]
	ret
.grc_gold:
	movzx eax, word [player_res_gold]
	ret

;================================================================
; inv_consume_resource
;----------------------------------------------------------------
; decrement the player's count of ingredient al if non-zero
; returns eax = 1 on success, 0 if empty
;================================================================
inv_consume_resource:
	cmp al, INGRED_WOOD
	je .crc_wood
	cmp al, INGRED_STONE
	je .crc_stone
	cmp al, INGRED_FOOD
	je .crc_food
	cmp al, INGRED_GOLD
	je .crc_gold
	xor eax, eax
	ret
.crc_wood:
	movzx ecx, word [player_res_wood]
	test ecx, ecx
	jz .crc_empty
	dec word [player_res_wood]
	mov eax, 1
	ret
.crc_stone:
	movzx ecx, word [player_res_stone]
	test ecx, ecx
	jz .crc_empty
	dec word [player_res_stone]
	mov eax, 1
	ret
.crc_food:
	movzx ecx, word [player_res_food]
	test ecx, ecx
	jz .crc_empty
	dec word [player_res_food]
	mov eax, 1
	ret
.crc_gold:
	movzx ecx, word [player_res_gold]
	test ecx, ecx
	jz .crc_empty
	dec word [player_res_gold]
	mov eax, 1
	ret
.crc_empty:
	xor eax, eax
	ret

;================================================================
; craft_recompute_result:
;----------------------------------------------------------------
; scan recipe_table; if any pattern matches the grid exactly, set 
; craft_result to that recipe's output. else set to ITEM_NONE
;================================================================
craft_recompute_result:
	push rbx
	push r12
	push r13

	; r12 = recipe table cursor
	lea r12, [recipe_table]
	mov r13d, RECIPE_COUNT
.next_recipe:
	test r13d, r13d
	jz .no_match

	; compare 9 pattern bytes with craft_grid
	xor ebx, ebx
.compare:
	cmp ebx, GRID_CELLS
	jge .matched

	mov al, [r12 + rbx]
	lea rcx, [craft_grid]
	mov dl, [rcx + rbx]
	cmp al, dl
	jne .no_this_recipe

	inc ebx
	jmp .compare
.matched:
	; pattern equal across all 9 cells - this recipe wins
	movzx eax, byte [r12 + GRID_CELLS]
	mov [craft_result], al
	jmp .out

.no_this_recipe:
	add r12, RECIPE_STRIDE
	dec r13d
	jmp .next_recipe

.no_match:
	mov byte [craft_result], ITEM_NONE
.out:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; craft_take_result
;----------------------------------------------------------------
; if there's a matching recipe and the player clicked the result
; slot, deduct one of each grid ingredient from the player's pool
; and grant +1 of the result item. the grid itself stays as-is so
; the player can keep clicking to craft repeats without rebuilding
;
; if the pool can't cover all the cells, refund whatever we took
; partway through and abort - no item granted, grid unchanged
;================================================================
craft_take_result:
	push rbx
	push r12
	push r13

	movzx eax, byte [craft_result]
	test eax, eax
	jz .out					; no recipe -> do nothing
	mov r13d, eax			; r13d = result item id

	; pass 1: deduct one from pool for each non-empty cell. r12d
	; holds the count of cells we've successfully deducted, so we
	; know how far to roll back on failure
	xor ebx, ebx			; cell index
	xor r12d, r12d			; deductions made
.deduct_loop:
	cmp ebx, GRID_CELLS
	jge .deducted
	lea rax, [craft_grid]
	movzx eax, byte [rax + rbx]
	test eax, eax
	jz .deduct_skip			; empty cell, skip
	; try to consume one from pool
	call inv_consume_resource
	test eax, eax
	jz .deduct_fail			; pool empty for this ingredient
	inc r12d
.deduct_skip:
	inc ebx
	jmp .deduct_loop

.deducted:
	; grant +1 result, leave grid alone
	movzx eax, word [inv_item_count + r13*2]
	inc eax
	mov [inv_item_count + r13*2], ax
	jmp .out

.deduct_fail:
	; pool ran out partway through. roll back r12d deductions by
	; walking the grid again and refunding the first r12d non-empty
	; cells we encounter
	xor ebx, ebx
.rollback_loop:
	test r12d, r12d
	jz .out					; nothing left to refund
	cmp ebx, GRID_CELLS
	jge .out
	lea rax, [craft_grid]
	movzx eax, byte [rax + rbx]
	test eax, eax
	jz .rollback_skip
	call inv_refund_ingredient
	dec r12d
.rollback_skip:
	inc ebx
	jmp .rollback_loop
.out:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; craft_clear_grid
;----------------------------------------------------------------
; refund every ingredient currently sitting in the grid back into
; the player's resource pool, then zero the grid. driven by the
; clear button next to the result slot
;================================================================
craft_clear_grid:
	push rbx
	xor ebx, ebx
.loop:
	cmp ebx, GRID_CELLS
	jge .done
	lea rax, [craft_grid]
	movzx eax, byte [rax + rbx]
	test eax, eax
	jz .next
	call inv_refund_ingredient
	lea rax, [craft_grid]
	mov byte [rax + rbx], 0
.next:
	inc ebx
	jmp .loop
.done:
	mov byte [craft_result], ITEM_NONE
	pop rbx
	ret

;================================================================
; mouse_in_rect: rectangle hit-test against the cached mouse position
;----------------------------------------------------------------
; in: edi = x, esi = y, edx = w, ecx = h
; out: eax = 1 if inside, 0 otherwise
;================================================================
mouse_in_rect:
	mov eax, [mouse_lx]
	cmp eax, edi
	jl .no
	mov r8d, edi
	add r8d, edx
	cmp eax, r8d
	jge .no
	mov eax, [mouse_ly]
	cmp eax, esi
	jl .no
	mov r8d, esi
	add r8d, ecx
	cmp eax, r8d
	jge .no
	mov eax, 1
	ret
.no:
	xor eax, eax
	ret

;================================================================
; inv_handle_click: process a left-click vs all clickable widgets
;----------------------------------------------------------------
; called by inv_update when mouse_l_clicked was raised this frame
;
; widgets tested in order:
;	- resource slots (left col): grab the whole stack onto the cursor
;	  (if cursor was already holding something, drop that back into
;	  resources first)
;	- grid cells: place 1 from the cursor stack into the cell. if the
;	  cell was already filled with something else, that gets refunded
;	  to resources first. drains the cursor when count hits 0
;	- result slot: take the crafted item
;	- placeable item slots (bottom row): select for placement & close
;================================================================
inv_handle_click:
	push rbx
	push r12
	push r13

	; --- resource slots ---
	; loop over the 4 resource ids (1..4 = wood, stone, food, gold)
	mov ebx, INGRED_WOOD	; current ingred id
.res_loop:
	cmp ebx, INGRED_COUNT
	jge .res_done

	; rect: (INV_RES_X, INV_RES_Y + (id-1)*INV_RES_PITCH,
	;		 INV_RES_SLOT_W, INV_RES_SLOT_H)
	mov edi, INV_RES_X
	mov esi, INV_RES_Y
	mov eax, ebx
	dec eax
	imul eax, INV_RES_PITCH
	add esi, eax
	mov edx, INV_RES_SLOT_W
	mov ecx, INV_RES_SLOT_H
	call mouse_in_rect
	test eax, eax
	jz .res_next

	; click landed - drop whatever the cursor was holding back into
	; resources, then grab the whole stack of this ingredient
	call inv_drop_cursor

	mov eax, ebx
	call inv_get_resource_count
	test eax, eax
	jz .out					; nothing to pick up - stay empty
	; cursor takes the entire stack, resource pool drains to 0
	mov [inv_cursor_ingred], bl
	mov [inv_cursor_count], ax
	; we know exactly how many there are, so just zero the pool rather
	; than looping consume_resource N times
	cmp bl, INGRED_WOOD
	je .zero_wood
	cmp bl, INGRED_STONE
	je .zero_stone
	cmp bl, INGRED_FOOD
	je .zero_food
	cmp bl, INGRED_GOLD
	je .zero_gold
	jmp .out
.zero_wood:
	mov word [player_res_wood], 0
	jmp .out
.zero_stone:
	mov word [player_res_stone], 0
	jmp .out
.zero_food:
	mov word [player_res_food], 0
	jmp .out
.zero_gold:
	mov word [player_res_gold], 0
	jmp .out

.res_next:
	inc ebx
	jmp .res_loop
.res_done:

	; --- grid cells ---
	; iterate all 9 cells. if a cell was clicked, drop one from the
	; cursor stack into it. if the cell was already non-empty,
	; refund the existing one back to resources first
	xor ebx, ebx			; cell index
.grid_loop:
	cmp ebx, GRID_CELLS
	jge .grid_done

	; cell rect
	mov eax, ebx
	xor edx, edx
	mov ecx, GRID_W
	div ecx					; eax = row, edx = col
	mov edi, edx
	imul edi, INV_GRID_CELL + INV_GRID_GAP
	add edi, INV_GRID_X
	mov esi, eax
	imul esi, INV_GRID_CELL + INV_GRID_GAP
	add esi, INV_GRID_Y
	mov edx, INV_GRID_CELL
	mov ecx, INV_GRID_CELL
	call mouse_in_rect
	test eax, eax
	jz .grid_next

	; cell hit - need cursor to actually have something to drop
	movzx eax, byte [inv_cursor_ingred]
	test eax, eax
	jz .out					; nothing held -> ignore

	; if cell already filled, refund the existing one (single)
	lea rcx, [craft_grid]
	movzx edx, byte [rcx + rbx]
	test edx, edx
	jz .grid_place
	push rax
	mov al, dl
	call inv_refund_ingredient
	pop rax
.grid_place:
	; write 1 cursor ingred into cell, decrement cursor count.
	; if count hits 0, clear the cursor type too
	lea rcx, [craft_grid]
	mov [rcx + rbx], al
	dec word [inv_cursor_count]
	jnz .grid_keep_cursor
	mov byte [inv_cursor_ingred], INGRED_NONE
.grid_keep_cursor:
	call craft_recompute_result
	jmp .out

.grid_next:
	inc ebx
	jmp .grid_loop
.grid_done:

	; --- result slot ---
	mov edi, INV_RESULT_X
	mov esi, INV_RESULT_Y
	mov edx, INV_RESULT_W
	mov ecx, INV_RESULT_H
	call mouse_in_rect
	test eax, eax
	jz .result_done
	call craft_take_result
	jmp .out
.result_done:

	; --- clear button ---
	mov edi, INV_CLEAR_X
	mov esi, INV_CLEAR_Y
	mov edx, INV_CLEAR_W
	mov ecx, INV_CLEAR_H
	call mouse_in_rect
	test eax, eax
	jz .clear_done
	call craft_clear_grid
	jmp .out
.clear_done:

	; --- placeable item slots (bottom row) ---
	; only the real items are clickable; the empty padding slots up to
	; INV_ITEMS_SLOTS are visual only
	mov ebx, ITEM_WOOD_FLOOR
.items_loop:
	cmp ebx, ITEM_COUNT
	jge .items_done
	mov edi, INV_ITEMS_X
	mov eax, ebx
	dec eax
	imul eax, INV_ITEMS_PITCH
	add edi, eax
	mov esi, INV_ITEMS_Y
	mov edx, INV_ITEMS_SLOT_W
	mov ecx, INV_ITEMS_SLOT_H
	call mouse_in_rect
	test eax, eax
	jz .items_next
	; select this item for placement (only if we have at least one)
	movzx eax, word [inv_item_count + rbx*2]
	test eax, eax
	jz .out					; have none, just ignore
	mov [place_item], bl
	mov byte [place_mode], 1
	; mirror choice on the hotbar so it lights up the same slot
	mov [hotbar_selected], bl
	; close inventory so the player can see the world for placement
	call inv_toggle
	jmp .out
.items_next:
	inc ebx
	jmp .items_loop
.items_done:

.out:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; inv_handle_rclick
;----------------------------------------------------------------
; if the cursor is holding anything, dump the entire stack back
; into resources - works wherever the mouse is. otherwise if hovering
; over a grid cell, refund just that cell's ingredient
;================================================================
inv_handle_rclick:
	; cursor non-empty -> dump the lot, no matter where the click
	; landed. rclick is always "release"
	movzx eax, byte [inv_cursor_ingred]
	test eax, eax
	jz .check_grid
	call inv_drop_cursor
	ret

.check_grid:
	push rbx
	xor ebx, ebx
.loop:
	cmp ebx, GRID_CELLS
	jge .done
	mov eax, ebx
	xor edx, edx
	mov ecx, GRID_W
	div ecx
	mov edi, edx
	imul edi, INV_GRID_CELL + INV_GRID_GAP
	add edi, INV_GRID_X
	mov esi, eax
	imul esi, INV_GRID_CELL + INV_GRID_GAP
	add esi, INV_GRID_Y
	mov edx, INV_GRID_CELL
	mov ecx, INV_GRID_CELL
	call mouse_in_rect
	test eax, eax
	jz .next

	lea rcx, [craft_grid]
	movzx eax, byte [rcx + rbx]
	test eax, eax
	jz .done				; already empty
	; refund the cell's single ingredient and clear it
	call inv_refund_ingredient
	lea rcx, [craft_grid]
	mov byte [rcx + rbx], 0
	call craft_recompute_result
	jmp .done
.next:
	inc ebx
	jmp .loop
.done:
	pop rbx
	ret

;================================================================
; inv_update: per-frame poll while the inventory screen is open
;----------------------------------------------------------------
; mouse polling itself happens in main.asm before this; we just react
; to the click flags it raised
;================================================================
inv_update:
	cmp byte [inv_open], 0
	je .out
	cmp byte [mouse_l_clicked], 0
	je .check_r
	mov byte [mouse_l_clicked], 0
	call inv_handle_click
.check_r:
	cmp byte [mouse_l_clicked], 0	; might have changed via close
	cmp byte [inv_open], 0
	je .out
	cmp byte [mouse_r_clicked], 0
	je .out
	mov byte [mouse_r_clicked], 0
	call inv_handle_rclick
.out:
	ret

;================================================================
; inv_draw: render the inventory screen
;----------------------------------------------------------------
; called after the world is drawn so it sits on top
;================================================================
inv_draw:
	cmp byte [inv_open], 0
	je .out

	; --- panel ---
	mov edi, INV_PANEL_X
	mov esi, INV_PANEL_Y
	mov edx, INV_PANEL_W
	mov ecx, INV_PANEL_H
	mov r8d, INV_PANEL_BG
	call fill_rect
	; thin border (top + bottom + left + right, 1px each)
	mov edi, INV_PANEL_X
	mov esi, INV_PANEL_Y
	mov edx, INV_PANEL_W
	mov ecx, 1
	mov r8d, INV_PANEL_BORDER
	call fill_rect
	mov edi, INV_PANEL_X
	mov esi, INV_PANEL_Y + INV_PANEL_H - 1
	mov edx, INV_PANEL_W
	mov ecx, 1
	mov r8d, INV_PANEL_BORDER
	call fill_rect
	mov edi, INV_PANEL_X
	mov esi, INV_PANEL_Y
	mov edx, 1
	mov ecx, INV_PANEL_H
	mov r8d, INV_PANEL_BORDER
	call fill_rect
	mov edi, INV_PANEL_X + INV_PANEL_W - 1
	mov esi, INV_PANEL_Y
	mov edx, 1
	mov ecx, INV_PANEL_H
	mov r8d, INV_PANEL_BORDER
	call fill_rect

	; --- title ---
	mov edi, INV_PANEL_X + 8
	mov esi, INV_PANEL_Y + 4
	mov edx, INV_TITLE_TEXT
	lea rcx, [inv_title_str]
	call debug_print

	; --- resources column ---
	mov edi, INV_RES_X
	mov esi, INV_RES_Y - 10
	mov edx, INV_DIM_TEXT
	lea rcx, [inv_label_resources]
	call debug_print
	; row per resource. label + ": " + count
	call inv_draw_resources

	; --- crafting grid ---
	mov edi, INV_GRID_X
	mov esi, INV_GRID_Y - 10
	mov edx, INV_DIM_TEXT
	lea rcx, [inv_label_grid]
	call debug_print
	call inv_draw_grid

	; --- arrow + result slot + clear button ---
	mov edi, INV_GRID_X + INV_GRID_W_PX + 6
	mov esi, INV_GRID_Y + INV_GRID_CELL + INV_GRID_GAP + 4
	mov edx, INV_PANEL_TEXT
	lea rcx, [inv_label_result]
	call debug_print
	call inv_draw_result
	call inv_draw_clear_button

	; --- placeable items list ---
	mov edi, INV_ITEMS_X
	mov esi, INV_ITEMS_Y - 10
	mov edx, INV_DIM_TEXT
	lea rcx, [inv_label_items]
	call debug_print
	call inv_draw_items

	; --- cursor (held ingredient follows the mouse) ---
	call inv_draw_cursor
.out:
	ret

;================================================================
; inv_blit_icon
;----------------------------------------------------------------
; blit one 8x8 icon from icons_tex at (dst_x, dst_y)
; icons_tex layout:heart=0, wood=1, stone=2, food=3, gold=4, matches
;the slot table in ingred_icon_slot,which conveniently makes INGRED_*
; usable directly as a slot index for resource icons
;----------------------------------------------------------------
; in:	edi = dst_x, esi = dst_y, edx = ingred id (INGRED_*)
;================================================================
inv_blit_icon:
	; src_x = ingred_icon_slot[id] * 8, src_y = 0
	push rbp
	mov rbp, rsp
	; entry rsp%16 = 8; +rbp = aligned. with our 2 stack args at the
	; bottom we'll be aligned again at the call

	lea rax, [ingred_icon_slot]
	movzx eax, byte [rax + rdx]
	shl eax, 3				; * 8 - icons are 8 wide

	mov r9d, edi			; dst_x
	mov r10d, esi			; saved dst_y for stack push
	lea rdi, [icons_tex]
	mov esi, eax			; src_x
	xor edx, edx			; src_y - icons are on row 0
	mov ecx, 8				; src_w
	mov r8d, 8				; src_h
	push 0					; flip
	push r10				; dst_y
	call blit_texture_rect
	add rsp, 16

	pop rbp
	ret

;================================================================
; inv_draw_resources: 4 rows, each with an 8x8 icon + "Name: nnn"
;----------------------------------------------------------------
; rows are clickable - hover gets a light highlight
;================================================================
inv_draw_resources:
	push rbx
	push r12
	mov ebx, INGRED_WOOD	; current ingred id
	mov r12d, INV_RES_Y		; current row y
.loop:
	cmp ebx, INGRED_COUNT
	jge .done

	; hover highlight
	mov edi, INV_RES_X
	mov esi, r12d
	mov edx, INV_RES_SLOT_W
	mov ecx, INV_RES_SLOT_H
	call mouse_in_rect
	test eax, eax
	jz .no_hover
	mov edi, INV_RES_X
	mov esi, r12d
	mov edx, INV_RES_SLOT_W
	mov ecx, INV_RES_SLOT_H
	mov r8d, 0x40FFFFFF
	call fill_rect
.no_hover:
	; 8x8 icon at the start of the row
	mov edi, INV_RES_X
	mov esi, r12d
	add esi, 1				; nudge down so it sits on the row baseline
	mov edx, ebx
	call inv_blit_icon

	; "Name: nnn" via debug_print_label_int (rcx=label, r8d=value)
	cmp ebx, INGRED_WOOD
	je .nm_wood
	cmp ebx, INGRED_STONE
	je .nm_stone
	cmp ebx, INGRED_FOOD
	je .nm_food
	jmp .nm_gold
.nm_wood:
	lea rcx, [inv_res_name_wood]
	movzx r8d, word [player_res_wood]
	jmp .nm_print
.nm_stone:
	lea rcx, [inv_res_name_stone]
	movzx r8d, word [player_res_stone]
	jmp .nm_print
.nm_food:
	lea rcx, [inv_res_name_food]
	movzx r8d, word [player_res_food]
	jmp .nm_print
.nm_gold:
	lea rcx, [inv_res_name_gold]
	movzx r8d, word [player_res_gold]
.nm_print:
	mov edi, INV_RES_X + 11
	mov esi, r12d
	add esi, 1
	mov edx, INV_PANEL_TEXT
	call debug_print_label_int

	add r12d, INV_RES_PITCH
	inc ebx
	jmp .loop
.done:
	pop r12
	pop rbx
	ret

;================================================================
; inv_draw_grid
;----------------------------------------------------------------
; 3x3 craft grid - each cell is a square. ingredient (if any)
; drawn as a tinted background with the 8x8 icon centred over it
;================================================================
inv_draw_grid:
	push rbx
	push r12
	push r13
	push r14
	xor ebx, ebx		; cell index 0..8
.loop:
	cmp ebx, GRID_CELLS
	jge .done

	; cell screen rect: (cell_x, cell_y, INV_GRID_CELL, INV_GRID_CELL)
	; r13d = cell_x, r14d = cell_y - kept across calls
	mov eax, ebx
	xor edx, edx
	mov ecx, GRID_W
	div ecx				; eax = row, edx = col
	mov r13d, edx
	imul r13d, INV_GRID_CELL + INV_GRID_GAP
	add r13d, INV_GRID_X
	mov r14d, eax
	imul r14d, INV_GRID_CELL + INV_GRID_GAP
	add r14d, INV_GRID_Y

	; cell background
	mov edi, r13d
	mov esi, r14d
	mov edx, INV_GRID_CELL
	mov ecx, INV_GRID_CELL
	mov r8d, 0xFF202830
	call fill_rect

	; hover highlight
	mov edi, r13d
	mov esi, r14d
	mov edx, INV_GRID_CELL
	mov ecx, INV_GRID_CELL
	call mouse_in_rect
	test eax, eax
	jz .no_hover
	mov edi, r13d
	mov esi, r14d
	mov edx, INV_GRID_CELL
	mov ecx, INV_GRID_CELL
	mov r8d, 0x40FFFFFF
	call fill_rect
.no_hover:
	; ingredient icon if any
	lea rcx, [craft_grid]
	movzx r12d, byte [rcx + rbx]
	test r12d, r12d
	jz .next				; empty cell

	; tinted background under the icon - icons are opaque art so this
	; only peeks out around the 8x8 icon edges, but it makes the cell
	; read as "this is wood" at a glance
	lea rcx, [ingred_swatch_colour]
	mov r8d, [rcx + r12*4]
	mov edi, r13d
	add edi, 3
	mov esi, r14d
	add esi, 3
	mov edx, INV_GRID_CELL - 6
	mov ecx, INV_GRID_CELL - 6
	call fill_rect

	; centre the 8x8 icon in the 18x18 cell
	mov edi, r13d
	add edi, (INV_GRID_CELL - 8) / 2
	mov esi, r14d
	add esi, (INV_GRID_CELL - 8) / 2
	mov edx, r12d
	call inv_blit_icon
.next:
	inc ebx
	jmp .loop
.done:
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; inv_draw_result: single cell to the right of the grid showing the
; product of the current pattern (or empty)
;================================================================
inv_draw_result:
	; cell background
	mov edi, INV_RESULT_X
	mov esi, INV_RESULT_Y
	mov edx, INV_RESULT_W
	mov ecx, INV_RESULT_H
	mov r8d, 0xFF302820
	call fill_rect

	; hover highlight
	mov edi, INV_RESULT_X
	mov esi, INV_RESULT_Y
	mov edx, INV_RESULT_W
	mov ecx, INV_RESULT_H
	call mouse_in_rect
	test eax, eax
	jz .no_hover
	mov edi, INV_RESULT_X
	mov esi, INV_RESULT_Y
	mov edx, INV_RESULT_W
	mov ecx, INV_RESULT_H
	mov r8d, 0x40FFFFFF
	call fill_rect
.no_hover:

	movzx eax, byte [craft_result]
	test eax, eax
	jz .out		; empty result

	; draw the actual tile graphic from the atlas
	; ITEM_* -> tile id -> atlas slot
	lea rcx, [item_tile_id]
	movzx eax, byte [rcx + rax]
	lea rcx, [tile_atlas_base]
	movzx eax, byte [rcx + rax]
	; eax = atlas slot. row = slot / COLS, col = slot % COLS
	xor edx, edx
	mov ecx, ATLAS_COLS
	div ecx
	; eax = row, edx = col
	mov r10d, edx
	imul r10d, TILE_SIZE	; src_x
	mov r11d, eax
	imul r11d, TILE_SIZE	; src_y

	; blit_texture_rect_keyed: same args as plain, plus colour key
	; at [rbp+32].  using keyed here for transp craft items in hud
	lea rdi, [atlas_tex]
	mov esi, r10d
	mov edx, r11d
	mov ecx, TILE_SIZE
	mov r8d, TILE_SIZE
	mov r9d, INV_RESULT_X + (INV_RESULT_W - TILE_SIZE)/2
	mov r10, 0xFFFF00FF		; magenta key
	push r10
	push 0	; flip
	push INV_RESULT_Y + (INV_RESULT_H - TILE_SIZE)/2
	call blit_texture_rect_keyed
	add rsp, 24
.out:
	ret

;================================================================
; inv_draw_clear_button
;----------------------------------------------------------------
; small square below the result slot. only "active" looking when
; there's actually something to clear - otherwise it dims down so
; it doesn't draw the eye when irrelevant
;================================================================
inv_draw_clear_button:
	; check if grid has anything in it - drives the colour
	push rbx
	xor ebx, ebx
	xor eax, eax			; eax = "any cell filled" flag
.scan:
	cmp ebx, GRID_CELLS
	jge .scanned
	lea rcx, [craft_grid]
	movzx ecx, byte [rcx + rbx]
	test ecx, ecx
	jz .scan_skip
	mov eax, 1
	jmp .scanned
.scan_skip:
	inc ebx
	jmp .scan
.scanned:
	; pick background colour: dim if empty, redder when there's
	; stuff to clear
	test eax, eax
	jz .bg_dim
	mov r8d, 0xFF502828
	jmp .have_bg
.bg_dim:
	mov r8d, 0xFF202830
.have_bg:
	mov edi, INV_CLEAR_X
	mov esi, INV_CLEAR_Y
	mov edx, INV_CLEAR_W
	mov ecx, INV_CLEAR_H
	call fill_rect

	; hover highlight
	mov edi, INV_CLEAR_X
	mov esi, INV_CLEAR_Y
	mov edx, INV_CLEAR_W
	mov ecx, INV_CLEAR_H
	call mouse_in_rect
	test eax, eax
	jz .no_hover
	mov edi, INV_CLEAR_X
	mov esi, INV_CLEAR_Y
	mov edx, INV_CLEAR_W
	mov ecx, INV_CLEAR_H
	mov r8d, 0x40FFFFFF
	call fill_rect
.no_hover:

	; centred "X" glyph
	mov edi, INV_CLEAR_X + (INV_CLEAR_W - DEBUG_GLYPH_W) / 2
	mov esi, INV_CLEAR_Y + (INV_CLEAR_H - DEBUG_GLYPH_H) / 2
	mov edx, INV_PANEL_TEXT
	lea rcx, [inv_label_clear]
	call debug_print
	pop rbx
	ret

;================================================================
; inv_draw_items: bottom row of placeable items
;----------------------------------------------------------------
; INV_ITEMS_SLOTS boxes drawn unconditionally as a horizontal row
; only the first ITEM_COUNT-1 are real item types; we draw a tile
; graphic + count only for slots whose item type is real and has
; a non-zero player count
;================================================================
inv_draw_items:
	push rbx
	xor ebx, ebx			; slot index 0..INV_ITEMS_SLOTS-1
.loop:
	cmp ebx, INV_ITEMS_SLOTS
	jge .done

	; slot rect x = INV_ITEMS_X + slot * pitch
	mov edi, INV_ITEMS_X
	mov eax, ebx
	imul eax, INV_ITEMS_PITCH
	add edi, eax
	mov esi, INV_ITEMS_Y
	mov edx, INV_ITEMS_SLOT_W
	mov ecx, INV_ITEMS_SLOT_H
	mov r8d, 0xFF202830
	call fill_rect

	; hover highlight
	mov edi, INV_ITEMS_X
	mov eax, ebx
	imul eax, INV_ITEMS_PITCH
	add edi, eax
	mov esi, INV_ITEMS_Y
	mov edx, INV_ITEMS_SLOT_W
	mov ecx, INV_ITEMS_SLOT_H
	call mouse_in_rect
	test eax, eax
	jz .no_hover
	mov edi, INV_ITEMS_X
	mov eax, ebx
	imul eax, INV_ITEMS_PITCH
	add edi, eax
	mov esi, INV_ITEMS_Y
	mov edx, INV_ITEMS_SLOT_W
	mov ecx, INV_ITEMS_SLOT_H
	mov r8d, 0x40FFFFFF
	call fill_rect
.no_hover:

	; map slot -> item id. items are stored at index 1..ITEM_COUNT-1
	; so item_id = slot + 1, and slot >= ITEM_COUNT-1 is just a blank
	mov eax, ebx
	inc eax					; eax = item id candidate
	cmp eax, ITEM_COUNT
	jge .next_item			; no real item for this slot

	; only draw tile + count if the player has any of this item
	movzx ecx, word [inv_item_count + rax*2]
	test ecx, ecx
	jz .next_item

	; stash count on stack across the blit. r10/r11 are caller-saved
	; and blit_texture_rect *will* clobber them - using them to hold
	; the count was the bug that drew "44......2.." (printing junk).
	; for the keyed blit we push 3 stack args (24 bytes), which
	; combined with our push rcx (8 bytes) makes 32 - aligned, no
	; extra padding needed
	push rcx

	; tile graphic - eax still holds item id at this point
	lea rcx, [item_tile_id]
	movzx eax, byte [rcx + rax]
	lea rcx, [tile_atlas_base]
	movzx eax, byte [rcx + rax]
	xor edx, edx
	mov ecx, ATLAS_COLS
	div ecx
	mov r10d, edx
	imul r10d, TILE_SIZE
	mov edx, eax
	imul edx, TILE_SIZE

	lea rdi, [atlas_tex]
	mov esi, r10d
	mov ecx, TILE_SIZE
	mov r8d, TILE_SIZE
	mov r9d, INV_ITEMS_X
	mov eax, ebx
	imul eax, INV_ITEMS_PITCH
	add r9d, eax
	add r9d, (INV_ITEMS_SLOT_W - TILE_SIZE)/2
	mov r10, 0xFFFF00FF		; magenta key
	push r10
	push 0					; flip
	push INV_ITEMS_Y + (INV_ITEMS_SLOT_H - TILE_SIZE)/2
	call blit_texture_rect_keyed
	add rsp, 24				; 3 stack args

	pop rcx					; rcx = count

	; count in the corner
	mov edi, INV_ITEMS_X
	mov eax, ebx
	imul eax, INV_ITEMS_PITCH
	add edi, eax
	add edi, INV_ITEMS_SLOT_W - 8
	mov esi, INV_ITEMS_Y + INV_ITEMS_SLOT_H - 8
	mov edx, INV_TITLE_TEXT
	call debug_print_int
.next_item:
	inc ebx
	jmp .loop
.done:
	pop rbx
	ret

;================================================================
; inv_draw_cursor: ingredient icon + stack count following the mouse
;----------------------------------------------------------------
; offset slightly from the cursor so it doesn't sit *on* whatever
; the mouse is hovering. count is drawn just to the right of the icon
;================================================================
inv_draw_cursor:
	movzx eax, byte [inv_cursor_ingred]
	test eax, eax
	jz .out

	; icon at mouse + (4,4)
	mov edi, [mouse_lx]
	add edi, 4
	mov esi, [mouse_ly]
	add esi, 4
	mov edx, eax
	call inv_blit_icon

	; count to the right - skip if somehow zero (shouldn't happen but
	; harmless if it does)
	movzx ecx, word [inv_cursor_count]
	test ecx, ecx
	jz .out
	mov edi, [mouse_lx]
	add edi, 4 + 9			; just past the 8px icon + 1 gap
	mov esi, [mouse_ly]
	add esi, 4
	mov edx, INV_PANEL_TEXT
	call debug_print_int
.out:
	ret

; ---------- placement mode helpers ----------
; 
;================================================================
; place_is_active: 1 if player is currently holding a placeable item
;================================================================
place_is_active:
	movzx eax, byte [place_mode]
	ret

;================================================================
; place_cancel: leave placement mode without spending the item
;================================================================
place_cancel:
	mov byte [place_mode], 0
	mov byte [place_item], ITEM_NONE
	ret

;================================================================
; place_mouse_to_tile
;----------------------------------------------------------------
; convert the cached mouse_lx/ly into world tile coords. mouse_lx
; is in framebuffer pixels, camera_x adds the world offset
;----------------------------------------------------------------
; out:	ebx = tx, r12d = ty (caller must have these saved)
;================================================================
place_mouse_to_tile:
	mov eax, [mouse_lx]
	add eax, [camera_x]
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	; floor for negatives - mouse outside the world top/left
	test edx, edx
	jns .x_ok
	dec eax
.x_ok:
	mov ebx, eax

	mov eax, [mouse_ly]
	add eax, [camera_y]
	cdq
	idiv ecx
	test edx, edx
	jns .y_ok
	dec eax
.y_ok:
	mov r12d, eax
	ret

;================================================================
; place_at_mouse
;----------------------------------------------------------------
; try to place the currently-selected item in the tile under the
; mouse cursor. on success, decrement the item count and (if that
; took us to zero) leave placement mode. on a placeable-tile miss,
; spawn a "blocked" floattext on the player
;----------------------------------------------------------------
; out:	eax = 1 placed, 0 if no place mode / blocked / oob
;================================================================
place_at_mouse:
	push rbx
	push r12

	cmp byte [place_mode], 0
	je .fail_silent		; not in place mode -> nothing to do, no msg

	call place_mouse_to_tile

	; bounds
	test ebx, ebx
	js .fail
	cmp ebx, MAP_WIDTH
	jge .fail
	test r12d, r12d
	js .fail
	cmp r12d, MAP_HEIGHT
	jge .fail

	; only allow placing on grass/dirt/floor ground - and the
	; cell must not already have a blocking object on it
	mov edi, ebx
	mov esi, r12d
	call tile_at
	cmp eax, TILE_GRASS
	je .ground_ok
	cmp eax, TILE_DIRT
	je .ground_ok
	cmp eax, TILE_WOOD_FLOOR
	je .ground_ok
	jmp .fail
.ground_ok:
	mov edi, ebx
	mov esi, r12d
	call object_at
	test eax, eax
	jz .ok				; nothing there
	jmp .fail			; tree, wall, door, furniture - blocks

.ok:
	; resolve item -> tile/object id
	movzx eax, byte [place_item]
	lea rcx, [item_tile_id]
	movzx eax, byte [rcx + rax]

	; doors: pick NS vs EW from the tile's neighbours.  the item
	; table maps to the NS-closed variant by default, but if the
	; wall runs east-west around this tile we want the EW variant
	; instead
	cmp byte [place_item], ITEM_WOOD_DOOR
	jne .layer_pick
	mov edi, ebx
	mov esi, r12d
	call door_pick_orientation
	; eax now holds the chosen door tile id (NS or EW closed)

.layer_pick:
	; floor goes to the GROUND layer (replaces grass/dirt).
	; everything else (wall, door, bed, chair) goes to OBJECTS
	; with the existing ground left intact.  this is what gives
	; us furniture-on-grass and door-with-floor-underneath
	mov ecx, r12d
	imul ecx, MAP_WIDTH
	add ecx, ebx
	cmp byte [place_item], ITEM_WOOD_FLOOR
	jne .write_object
	; floor: write to tilemap
	lea rdx, [tilemap]
	mov [rdx + rcx], al
	jmp .placed_count
.write_object:
	; wall/door/bed/chair: write to objectmap
	lea rdx, [objectmap]
	mov [rdx + rcx], al
	; roll a random variant byte for this cell.  walls in particular
	; use this to break the position-hash checkerboard and pick a
	; set independently of where they're placed.  preserved across
	; the rng_next call by saving rcx on the stack
	push rcx
	sub rsp, 8					; align for the call
	call rng_next
	add rsp, 8
	pop rcx
	lea rdx, [object_variant]
	mov [rdx + rcx], al

.placed_count:
	; decrement count
	movzx eax, byte [place_item]
	movzx ecx, word [inv_item_count + rax*2]
	dec ecx
	mov [inv_item_count + rax*2], cx
	; if zero left, drop placement mode
	test ecx, ecx
	jnz .placed
	mov byte [place_mode], 0
	mov byte [place_item], ITEM_NONE
.placed:
	; the placement may have changed lights or occluders -
	; rebuild the gameplay safezone mask and the hub flow field
	call safezone_recompute
	call pathing_recompute
	mov eax, 1
	pop r12
	pop rbx
	ret
.fail:
	; we tried to place but the target was blocked - tell the player
	lea rdi, [inv_msg_blocked]
	call spawn_floattext
.fail_silent:
	xor eax, eax
	pop r12
	pop rbx
	ret

;================================================================
; place_draw_cursor
;----------------------------------------------------------------
; in placement mode, outline the tile under the mouse cursor
; green for an eligible spot, red for a blocked one
;================================================================
place_draw_cursor:
	cmp byte [place_mode], 0
	je .out
	push rbx
	push r12
	push r13
	push r14

	call place_mouse_to_tile

	; if mouse is way off the map don't draw anything (would clamp to
	; the edge tile and look wrong)
	test ebx, ebx
	js .clean_out
	cmp ebx, MAP_WIDTH
	jge .clean_out
	test r12d, r12d
	js .clean_out
	cmp r12d, MAP_HEIGHT
	jge .clean_out

	; eligibility colour -> r13d
	mov edi, ebx
	mov esi, r12d
	call tile_at
	mov r13d, 0xFFE04040	; red (blocked default)
	cmp eax, TILE_GRASS
	je .ground_ok_for_colour
	cmp eax, TILE_DIRT
	je .ground_ok_for_colour
	cmp eax, TILE_WOOD_FLOOR
	je .ground_ok_for_colour
	jmp .have_colour
.ground_ok_for_colour:
	; ground is fine - check object isn't blocking
	mov edi, ebx
	mov esi, r12d
	call object_at
	test eax, eax
	jnz .have_colour		; anything in objectmap blocks
.ok_colour:
	mov r13d, 0xFF40E060	; green
.have_colour:

	; world -> screen origin in r14d:r12d
	; (reuse r14d=x_screen, r12d=y_screen)
	mov edi, ebx
	imul edi, TILE_SIZE
	sub edi, [camera_x]
	mov r14d, edi			; r14d = sx
	mov esi, r12d
	imul esi, TILE_SIZE
	sub esi, [camera_y]
	mov r12d, esi			; r12d = sy

	; top edge (full width, 1px tall)
	mov edi, r14d
	mov esi, r12d
	mov edx, TILE_SIZE
	mov ecx, 1
	mov r8d, r13d
	call fill_rect
	; bottom edge
	mov edi, r14d
	mov esi, r12d
	add esi, TILE_SIZE - 1
	mov edx, TILE_SIZE
	mov ecx, 1
	mov r8d, r13d
	call fill_rect
	; left edge
	mov edi, r14d
	mov esi, r12d
	mov edx, 1
	mov ecx, TILE_SIZE
	mov r8d, r13d
	call fill_rect
	; right edge
	mov edi, r14d
	add edi, TILE_SIZE - 1
	mov esi, r12d
	mov edx, 1
	mov ecx, TILE_SIZE
	mov r8d, r13d
	call fill_rect

.clean_out:
	pop r14
	pop r13
	pop r12
	pop rbx
.out:
	ret

;================================================================
; hotbar_set_select
;----------------------------------------------------------------
; pick item id #al as the hotbar selection, and if we have at
; least one of it, drop into placement mode.  if we have none,
; we still record the selection (so the slot lights up) but the
; game won't enter placement until the player crafts one
;----------------------------------------------------------------
; in:	al = item id (ITEM_NONE/.WOOD_FLOOR/..ITEM_COUNT-1)
;================================================================
hotbar_set_select:
	cmp al, ITEM_COUNT
	jge .out			; out of range -> ignore
	cmp al, ITEM_NONE
	je .clear

	mov [hotbar_selected], al
	movzx ecx, al
	movzx edx, word [inv_item_count + rcx*2]
	test edx, edx
	jz .out				; selected but none owned -> no place mode
	mov [place_item], al
	mov byte [place_mode], 1
.out:
	ret
.clear:
	mov byte [hotbar_selected], ITEM_NONE
	; don't auto-cancel placement here - q already does that
	ret

;================================================================
; hotbar_cycle
;----------------------------------------------------------------
; advance the hotbar selection by +1 or -1, wrapping across the
; range of real items.  used by mouse wheel handler.  ignores
; any items the player has zero of, so we cycle only among
; useful slots
;
; if every slot is empty, we just clear the selection
;----------------------------------------------------------------
; in:	edi = delta (+1 or -1, only the sign matters)
;================================================================
hotbar_cycle:
	push rbx
	push r12
	push r13

	; ebx = current selection (or 0 = none)
	movzx ebx, byte [hotbar_selected]
	; clamp delta to +/-1.  invert so wheel-down (sdl negative)
	; advances to the next slot
	mov r12d, edi
	test r12d, r12d
	jns .pos
	mov r12d, 1
	jmp .have_step
.pos:
	mov r12d, -1
.have_step:

	; r13 = max attempts (one full lap through real items)
	mov r13d, ITEM_COUNT - 1
.try_loop:
	test r13d, r13d
	jz .none_found

	; advance ebx by step, wrapping in [1, ITEM_COUNT-1]
	add ebx, r12d
	cmp ebx, ITEM_COUNT
	jl .no_wrap_high
	mov ebx, 1			; wrapped past the end
.no_wrap_high:
	cmp ebx, 1
	jge .no_wrap_low
	mov ebx, ITEM_COUNT - 1	; wrapped past the start
.no_wrap_low:

	; do we own any of this item?
	movzx eax, word [inv_item_count + rbx*2]
	test eax, eax
	jnz .pick

	dec r13d
	jmp .try_loop

.pick:
	; selected ebx as the new item
	mov al, bl
	call hotbar_set_select
	jmp .out

.none_found:
	; nothing in inventory at all - clear it out
	mov byte [hotbar_selected], ITEM_NONE
.out:
	pop r13
	pop r12
	pop rbx
	ret

%endif