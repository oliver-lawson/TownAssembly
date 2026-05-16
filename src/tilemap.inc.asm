; tilemap.inc.asm - tile-based worldmap and renderer
;
; world is a 2d grid of tile_id bytes.  rendering picks the right
; atlas slot per tile - sometimes from a fixed base, sometimes
; computed from neighbours (autotiling)
;
; ----- atlas layout (16 cols wide) -----
;
; every autotile "set" is a 4-row x 16-col block:
;	cols 0..11 = 12-wide blob slot pack (47 unique + 1 spare,
;				 row-major: slot index = (local_row * 12) + col)..
;				 slot indices map to neighbour masks per the table
;				 baked into autotile.inc.asm
;	cols 12..15 = 16 variant slots, picked at random for the
;				 "fully surrounded" centre case (mask 0xFF/slot 46)
;				 to give big interior patches some variatino
;
; row 0 = non-autotiled tiles, fits in 16 slots. see below for list
;
; row 1 (decoration ground 1):
;	0..7   = dirt-ground variants (8, picked by hash - opaque soil
;			 for the exposed floor under dug stone walls + the
;			 natural dirt patches from worldgen) 
;	8..15  = spare atm
;
; row 2 (decoration ground 2):
;	0..7   = flower overlays (8 variants, picked by hash, drawn
;			 with magenta key on top of some % of grass tiles for
;			 decoration)
;	8..11  = wood floor variants (hashed)
;	12..15 = spare
;
; row 3 (torch animation):
;	0..7   = torch flame frames (8-frame loop, drawn as object
;			 overlay with magenta key). cols 8..15 spare
;
; row 4 (blood splatters):
;	0..15  = 16 blood splatter variants, magenta-keyed.  drawn by
;			 bloodmap.inc.asm; the count byte per tile picks how
;			 many stack and the per-tile hash picks the start index
;
; rows 5..16 (GRASS band, 3 sets, each 4 rows):
;	rows 5..8	: grass set 0  (blob pack + 16 variants)
;	rows 9..12	: grass set 1
;	rows 13..16	: grass set 2
;
; rows 17..28 (STONE band, 3 sets, same shape as grass)
;
; rows 29..32 (WOOD WALL band, 1 set):
;	standard 4-row set with blob pack + 16 variants
;
; rows 33..48 (WATER band, 1 set with 4 animation frames):
;	rows 33..36 : water frame 0  (blob pack + 16 variants)
;	rows 37..40 : water frame 1
;	rows 41..44 : water frame 2
;	rows 45..48 : water frame 3
;
; total: 49 rows * 16 cols = 784 slots, 256 x 784 px

%ifndef TILEMAP_INC
%define TILEMAP_INC

%define TILE_SIZE 16
%define MAP_WIDTH 80	; 80*16 = 1280 px wide, 2x WINDOW_W
%define MAP_HEIGHT 60	; 60*16 = 960 px tall,  2x WINDOW_H

; tile IDs - matches what the world stores in tilemap[]
%define TILE_GRASS				0
%define TILE_WATER				1
%define TILE_STONE				2
%define TILE_DIRT				3
%define TILE_TREE				4
%define TILE_WOOD_FLOOR			5
%define TILE_WOOD_WALL			6
%define TILE_WOOD_DOOR_NS_C		7
%define TILE_WOOD_DOOR_NS_O		8
%define TILE_WOOD_DOOR_EW_C		9
%define TILE_WOOD_DOOR_EW_O		10
%define TILE_BED				11
%define TILE_CHAIR				12
%define TILE_TORCH				13
%define TILE_COUNT				14

; backwards-compat alias - "the" door from older code is door_ns_c
%define TILE_WOOD_DOOR			TILE_WOOD_DOOR_NS_C


; -- atlas layout --
%define ATLAS_COLS			16

; size of one autotile set: 4 rows tall, 16 cols wide
; (cols 0..11 = blob pack, cols 12..15 = variants strip)
%define AUTOTILE_SET_ROWS	4
%define BLOB_COLS			12
%define BLOB_SLOT_COUNT	47			; valid masks (the 48th is spare)
%define VARIANT_COLS		4			; cols 12..15 within a set
%define VARIANT_COUNT		16			; 4 cols * 4 rows of variants

; row 0: non-autotiled tiles
%define ATLAS_WOOD_FLOOR		0
%define ATLAS_WOOD_WALL			1
%define ATLAS_WOOD_DOOR_NS_C	2
%define ATLAS_WOOD_DOOR_NS_O	3
%define ATLAS_WOOD_DOOR_EW_C	4
%define ATLAS_WOOD_DOOR_EW_O	5
%define ATLAS_BED				6
%define ATLAS_CHAIR				7
; row 0 cols 8..11 are stone preview/inventory slots; the blob
; picker doesn't use them (it pulls from the proper stone band
; below), but inventory icons still want a representative slot
%define ATLAS_STONE_VARIANTS	8	; 4 slots (8..11) - inventory only
%define ATLAS_TREE_VARIANTS		12	; 4 slots (12..15)
%define STONE_VARIANT_COUNT		4
%define TREE_VARIANT_COUNT		4

; row 1: dirt-ground variants
%define ATLAS_DIRT_GROUND_VARIANTS	(1 * ATLAS_COLS + 0)
%define DIRT_GROUND_VARIANT_COUNT	8

; row 2: flower overlays + wood floor variants
%define ATLAS_FLOWER_VARIANTS		(2 * ATLAS_COLS + 0)
%define FLOWER_VARIANT_COUNT		8
%define ATLAS_WOOD_FLOOR_VARIANTS	(2 * ATLAS_COLS + 8)
%define WOOD_FLOOR_VARIANT_COUNT	4

; per-tile chance that a grass tile gets a flower drawn over it
%define FLOWER_CHANCE_NUM			38 ;over..
%define FLOWER_CHANCE_DEN			256

; ----- autotile band base slots -----
; the value stored in *_set_bases is the atlas slot index of the
; top-left of that set's 12-col blob pack.  the picker computes
; the per-tile slot as set_base + (local_row*16 + local_col) since
; ATLAS_COLS=16 stride applies even though only cols 0..11 are
; blob slots.  variants strip starts at set_base + 12 (col 12 of
; the same top row)/steps by 16 per row

; grass band: rows 5..16, 3 sets stacked vertically (4 rows each).
; shifted from 4 to 5 to make room for the 1x16 blood row at row 4
%define GRASS_BAND_ROW			5
%define ATLAS_GRASS_SET_0	(GRASS_BAND_ROW * ATLAS_COLS + 0)
%define ATLAS_GRASS_SET_1	((GRASS_BAND_ROW + AUTOTILE_SET_ROWS) * ATLAS_COLS + 0)
%define ATLAS_GRASS_SET_2	((GRASS_BAND_ROW + AUTOTILE_SET_ROWS*2) * ATLAS_COLS + 0)
%define GRASS_SET_COUNT		3

; stone band: rows 17..28, same shape as grass
%define STONE_BAND_ROW			17
%define ATLAS_STONE_SET_0	(STONE_BAND_ROW * ATLAS_COLS + 0)
%define ATLAS_STONE_SET_1	((STONE_BAND_ROW + AUTOTILE_SET_ROWS) * ATLAS_COLS + 0)
%define ATLAS_STONE_SET_2	((STONE_BAND_ROW + AUTOTILE_SET_ROWS*2) * ATLAS_COLS + 0)
%define STONE_SET_COUNT		3

; wood wall band: rows 29..32, single set
%define WOOD_WALL_BAND_ROW		29
%define ATLAS_WOOD_WALL_SET_0	(WOOD_WALL_BAND_ROW * ATLAS_COLS + 0)
%define WOOD_WALL_SET_COUNT		1

; water band: rows 33..48, single set with 4 anim frames stacked
%define WATER_BAND_ROW			33
%define ATLAS_WATER_F0			(WATER_BAND_ROW * ATLAS_COLS + 0)
%define WATER_FRAME_COUNT		1
%define WATER_ANIM_PERIOD		12

; per-tile/object movement speed (% of normal)
; 0 = blocked, 100 = full speed
; the same table is indexed by both tile id (for ground) and
; object id (for the overlay), since the two id spaces share
; numeric values
section .data
	tile_speed_table:
		db 100		; grass
		db 50		; water
		db 0		; stone
		db 100		; dirt
		db 0		; tree
		db 100		; wood floor
		db 0		; wood wall
		db 0		; wood door ns closed
		db 100		; wood door ns open
		db 0		; wood door ew closed
		db 100		; wood door ew open
		db 0		; bed
		db 100		; chair
		db 100		; torch - walk through to plant/replace easily


	; tile_id -> base atlas slot.  used for non-autotiled tiles
	; in draw_tilemap, AND for inventory/hotbar previews of any
	; tile id.  for variant types (dirt, tree) we point at the
	; first variant
	tile_atlas_base:
		db 0						; grass (autotiled)
		db 0						; water	(autotiled)
		db ATLAS_STONE_VARIANTS		; stone (variant preview)
		db ATLAS_DIRT_GROUND_VARIANTS & 0xFF ; dirt(variant preview)
									;row 1 col 0=slot 16, fits a byte
		db ATLAS_TREE_VARIANTS		; tree (variant preview)
		db ATLAS_WOOD_FLOOR_VARIANTS & 0xFF;wood floor(var preview)
									; row 2 col 8=slot 40,fits a byte
		db ATLAS_WOOD_WALL			; wood wall (preview)
		db ATLAS_WOOD_DOOR_NS_C		; door ns closed
		db ATLAS_WOOD_DOOR_NS_O		; door ns open
		db ATLAS_WOOD_DOOR_EW_C		; door ew closed
		db ATLAS_WOOD_DOOR_EW_O		; door ew open
		db ATLAS_BED				; bed
		db ATLAS_CHAIR				; chair
		db (3 * ATLAS_COLS)			; torch(row 3 col 0=first frame)

	; -- autotile set base slots, indexed [tile_id][set_index] --
	; words because slots > 255.  the picker loads with movzx
	align 2
	grass_set_bases:
		dw ATLAS_GRASS_SET_0
		dw ATLAS_GRASS_SET_1
		dw ATLAS_GRASS_SET_2
	stone_set_bases:
		dw ATLAS_STONE_SET_0
		dw ATLAS_STONE_SET_1
		dw ATLAS_STONE_SET_2
	; water has only one set but 4 anim frames; the picker advances
	; the frame index at draw time.  base here is frame 0's top-left
	water_set_base:
		dw ATLAS_WATER_F0
	wood_wall_set_base:
		dw ATLAS_WOOD_WALL_SET_0


; ----- two-layer rendering -----
;
; tilemap[] is the GROUND layer.  every cell has a ground tile -
; grass, water, stone, dirt, wood floor.  drawn first, no
; transparency. z=-1
;
; objectmap[] is the OBJECT layer overlay.  most cells are
; OBJ_NONE; cells with a value get drawn on top of the ground
; using a magenta colour key (so the ground shows around them). z=0
; objects: trees, walls, doors (4 variants), beds, chairs, etc
;
; placing wood floor goes to tilemap; placing wall/door/bed/chair
; goes to objectmap, leaving the existing ground intact.
;
; OBJ_* ids re-use TILE_* numeric values, since the rendering
; path goes through tile_atlas_base[id] either way.  the only
; reserved value is OBJ_NONE = 0 (which would collide with
; TILE_GRASS, but objectmap entries are tested for non-zero
; before any atlas lookup so the collision is harmless)
%define OBJ_NONE			0
%define OBJ_TREE			TILE_TREE
; dig clears objectmap and sets the ground to TILE_DIRT, which
; paints opaquely under whatever else gets placed later
%define OBJ_STONE_WALL		TILE_STONE
%define OBJ_WOOD_WALL		TILE_WOOD_WALL
%define OBJ_WOOD_DOOR_NS_C	TILE_WOOD_DOOR_NS_C
%define OBJ_WOOD_DOOR_NS_O	TILE_WOOD_DOOR_NS_O
%define OBJ_WOOD_DOOR_EW_C	TILE_WOOD_DOOR_EW_C
%define OBJ_WOOD_DOOR_EW_O	TILE_WOOD_DOOR_EW_O
%define OBJ_BED				TILE_BED
%define OBJ_CHAIR			TILE_CHAIR
%define OBJ_TORCH			TILE_TORCH

section .bss
	alignb 8
	; -- tilemap: ground layer --
	tilemap resb MAP_WIDTH * MAP_HEIGHT
	; -- objectmap: object overlay layer --
	; cells default to OBJ_NONE (=0), bss zeros at startup
	objectmap resb MAP_WIDTH * MAP_HEIGHT
	; -- object_variant: per-cell stable RNG byte --
	; rolled at placement time and remembered for the lifetime of
	; that object.  unused for clels with no object
	object_variant resb MAP_WIDTH * MAP_HEIGHT

	; camera offset in pixels
	camera_x resd 1
	camera_y resd 1

	; global frame counter used to drive the tile animation
	; (bumped once per frame in main)
	tile_anim_ticks resd 1

	; -- tall-tile scratch list --
	; collected once per frame at the start of draw_entities and
	; consumed during the interleaved y-sort merge.  each entry is
	; ty * MAP_WIDTH + tx so we can recover the cell coordinates
	; without a second lookup.  already y-sorted from row by row scan
	%define TALL_TILE_MAX	512
	tall_tile_list		resd TALL_TILE_MAX
	tall_tile_count		resd 1

section .text

;================================================================
; tile_is_door
;----------------------------------------------------------------
; in:	eax = tile id
; out:	eax = 1 if door (any orientation/state), else 0
;================================================================
tile_is_door:
	cmp eax, TILE_WOOD_DOOR_NS_C
	jl .no
	cmp eax, TILE_WOOD_DOOR_EW_O
	jg .no
	mov eax, 1
	ret
.no:
	xor eax, eax
	ret

;================================================================
; tile_is_door_closed
;----------------------------------------------------------------
; we use this for npc auto-open behaviour - they only need to
; nudge a door when it's blocking them
;----------------------------------------------------------------
; in:	eax = tile id
; out:	eax = 1 if closed door, else 0
;================================================================
tile_is_door_closed:
	cmp eax, TILE_WOOD_DOOR_NS_C
	je .yes
	cmp eax, TILE_WOOD_DOOR_EW_C
	je .yes
	xor eax, eax
	ret
.yes:
	mov eax, 1
	ret

;================================================================
; tile_is_wall_like
;----------------------------------------------------------------
; tile blocks movement and looks structural.  used by door
; orientation autodetect at place time
;----------------------------------------------------------------
; in:	eax = tile id
; out:	eax = 1 if wall-like, else 0
;================================================================
tile_is_wall_like:
	cmp eax, TILE_WOOD_WALL
	je .yes
	cmp eax, TILE_STONE
	je .yes
	xor eax, eax
	ret
.yes:
	mov eax, 1
	ret

;================================================================
; tile_is_autotiled
;----------------------------------------------------------------
; does this tile_id participate in autotile rendering?
; central place to check! - draw_tilemap and any future caller
; can ask without baking the list in
;----------------------------------------------------------------
; in:	eax = tile id
; out:	eax = 1 if autotiled, else 0
;================================================================
tile_is_autotiled:
	cmp eax, TILE_GRASS
	je .yes
	cmp eax, TILE_WATER
	je .yes
	cmp eax, TILE_STONE
	je .yes
	cmp eax, TILE_WOOD_WALL
	je .yes
	xor eax, eax
	ret
.yes:
	mov eax, 1
	ret

;================================================================
; door_pick_orientation
;----------------------------------------------------------------
; checks the four tile neighbours: NS if N+S are walls, EW if
; W+E are walls.  if both are true (corner case), prefer NS
; if neither, default to NS
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = TILE_WOOD_DOOR_NS_C or TILE_WOOD_DOOR_EW_C
;================================================================
door_pick_orientation:
	push rbx
	push r12
	push r13
	push r14
	mov ebx, edi			; tx
	mov r12d, esi			; ty
	xor r13d, r13d			; ns flag
	xor r14d, r14d			; ew flag

	; N - check both ground (stone) and object (wood wall)
	mov edi, ebx
	mov esi, r12d
	dec esi
	call cell_is_wall_like
	test eax, eax
	jz .no_n
	; S
	mov edi, ebx
	mov esi, r12d
	inc esi
	call cell_is_wall_like
	test eax, eax
	jz .no_n
	mov r13d, 1				; both N+S walls -> ns
.no_n:

	; W
	mov edi, ebx
	dec edi
	mov esi, r12d
	call cell_is_wall_like
	test eax, eax
	jz .no_e
	; E
	mov edi, ebx
	inc edi
	mov esi, r12d
	call cell_is_wall_like
	test eax, eax
	jz .no_e
	mov r14d, 1				; both E+W walls -> ew
.no_e:

	test r13d, r13d
	jnz .ns
	test r14d, r14d
	jnz .ew
.ns:
	mov eax, TILE_WOOD_DOOR_NS_C
	jmp .out
.ew:
	mov eax, TILE_WOOD_DOOR_EW_C
.out:
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; cell_is_wall_like
;----------------------------------------------------------------
; layered version of tile_is_wall_like.  considers the cell at
; (tx, ty) "wall-like" if the GROUND is stone OR the OBJECT is
; a wood wall.  used by door_pick_orientation
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = 1 if wall-like, else 0
;================================================================
cell_is_wall_like:
	push rbx
	push r12
	mov ebx, edi
	mov r12d, esi

	; object check - either kind of wall counts
	mov edi, ebx
	mov esi, r12d
	call object_at
	cmp eax, OBJ_WOOD_WALL
	je .yes
	cmp eax, OBJ_STONE_WALL
	je .yes

	xor eax, eax
	jmp .out
.yes:
	mov eax, 1
.out:
	pop r12
	pop rbx
	ret

;================================================================
; door_toggle_at
;----------------------------------------------------------------
; closed <-> open, preserving NS/EW orientation.  no-op if
; the target isn't a door
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = 1 if a door was toggled, 0 otherwise
;================================================================
door_toggle_at:
	push rbx
	push r12
	mov ebx, edi			; tx
	mov r12d, esi			; ty

	mov edi, ebx
	mov esi, r12d
	call object_at			; eax = object id at this cell

	cmp eax, OBJ_WOOD_DOOR_NS_C
	je .ns_to_open
	cmp eax, OBJ_WOOD_DOOR_NS_O
	je .ns_to_closed
	cmp eax, OBJ_WOOD_DOOR_EW_C
	je .ew_to_open
	cmp eax, OBJ_WOOD_DOOR_EW_O
	je .ew_to_closed
	xor eax, eax
	jmp .out

.ns_to_open:
	mov eax, OBJ_WOOD_DOOR_NS_O
	jmp .write
.ns_to_closed:
	mov eax, OBJ_WOOD_DOOR_NS_C
	jmp .write
.ew_to_open:
	mov eax, OBJ_WOOD_DOOR_EW_O
	jmp .write
.ew_to_closed:
	mov eax, OBJ_WOOD_DOOR_EW_C
.write:
	mov ecx, r12d
	imul ecx, MAP_WIDTH
	add ecx, ebx
	lea rdx, [objectmap]
	mov [rdx + rcx], al
	mov eax, 1
.out:
	pop r12
	pop rbx
	ret

;================================================================
; tile_at: read tile id at (tx,ty)
;----------------------------------------------------------------
; off-grid returns stone so collision queries treat outside as
; a solid wall - keeps the player penned in
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = tile id (or TILE_STONE if oob)
;================================================================
tile_at:
	test edi, edi
	js .oob
	cmp edi, MAP_WIDTH
	jge .oob
	test esi, esi
	js .oob
	cmp esi, MAP_HEIGHT
	jge .oob
	mov eax, esi
	imul eax, MAP_WIDTH
	add eax, edi
	lea rdx, [tilemap]
	movzx eax, byte [rdx + rax]
	ret
.oob:
	mov eax, TILE_STONE
	ret

;================================================================
; object_at: read object id at (tx, ty)
;----------------------------------------------------------------
; companion to tile_at.  returns OBJ_NONE for out-of-bounds, so
; queries past the world edge are treated as "no object" - the
; ground's stone return from tile_at handles the wall-like
; behaviour
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = object id (or OBJ_NONE if oob)
;================================================================
object_at:
	test edi, edi
	js .none
	cmp edi, MAP_WIDTH
	jge .none
	test esi, esi
	js .none
	cmp esi, MAP_HEIGHT
	jge .none
	mov eax, esi
	imul eax, MAP_WIDTH
	add eax, edi
	lea rdx, [objectmap]
	movzx eax, byte [rdx + rax]
	ret
.none:
	xor eax, eax			; OBJ_NONE
	ret

;================================================================
; object_set: write object id at (tx, ty)
;----------------------------------------------------------------
; oob writes are silently dropped
;----------------------------------------------------------------
; in:	edi = tx, esi = ty, dl = object id
;================================================================
object_set:
	test edi, edi
	js .skip
	cmp edi, MAP_WIDTH
	jge .skip
	test esi, esi
	js .skip
	cmp esi, MAP_HEIGHT
	jge .skip
	mov eax, esi
	imul eax, MAP_WIDTH
	add eax, edi
	lea rcx, [objectmap]
	mov [rcx + rax], dl
.skip:
	ret

;================================================================
; object_at_pixel
;----------------------------------------------------------------
; like object_at but with pixel coords.  same floor-divide
; convention as tile_at_pixel
;----------------------------------------------------------------
; in:	edi = px, esi = py
; out:	eax = object id (or OBJ_NONE if oob)
;================================================================
object_at_pixel:
	mov eax, edi
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	test edx, edx
	jns .x_ok
	dec eax
.x_ok:
	mov edi, eax

	mov eax, esi
	cdq
	idiv ecx
	test edx, edx
	jns .y_ok
	dec eax
.y_ok:
	mov esi, eax

	jmp object_at

;================================================================
; tile_at_pixel: like tile_at but inputs are pixel coords
;----------------------------------------------------------------
; floor-divide so negative pixel coords give negative tile coords
; (caught by tile_at's bounds check).  idiv truncates toward
; zero, so for negatives with a remainder, decrement to floor
;----------------------------------------------------------------
; in:	edi = px, esi = py
; out:	eax = tile id
;================================================================
tile_at_pixel:
	mov eax, edi
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	test edx, edx
	jns .x_ok
	dec eax
.x_ok:
	mov edi, eax		; tx

	mov eax, esi
	cdq
	idiv ecx
	test edx, edx
	jns .y_ok
	dec eax
.y_ok:
	mov esi, eax		; ty

	jmp tile_at

;================================================================
; tile_speed_at_pixel
;----------------------------------------------------------------
; combined ground + object speed at the given pixel position.
; an empty object slot (OBJ_NONE) is treated as fully passable -
; it doesn't reduce the ground speed.  otherwise the object's
; speed entry from tile_speed_table wins over the ground if
; lower (so a tree on grass is blocked, not 100%, even though
; grass alone would be 100%)
;----------------------------------------------------------------
; in:	edi = px, esi = py
; out:	eax = speed % (0..100)
;================================================================
tile_speed_at_pixel:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	push r13
	; 3 callee-saves + ret + rbp = 40, sub 8 to align
	sub rsp, 8

	; stash pixel coords in callee-saved regs
	mov ebx, edi
	mov r12d, esi

	; ground speed
	mov edi, ebx
	mov esi, r12d
	call tile_at_pixel
	lea rcx, [tile_speed_table]
	movzx r13d, byte [rcx + rax]		; r13d = ground speed

	; object overlay
	mov edi, ebx
	mov esi, r12d
	call object_at_pixel
	test eax, eax
	jz .no_object			; OBJ_NONE - just use ground

	lea rcx, [tile_speed_table]
	movzx eax, byte [rcx + rax]
	; combined = min(ground, object)
	cmp eax, r13d
	jle .have_speed
	mov eax, r13d
	jmp .have_speed
.no_object:
	mov eax, r13d
.have_speed:
	add rsp, 8
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret


;================================================================
; autotile_pick_slot
;----------------------------------------------------------------
; resolves a tile to its full atlas slot for one of the autotiled
; types (grass, stone, water, wood wall) using the blob scheme.
;
;	1. compute the blob slot 0..46 from the 8-neighbour mask
;	2. pick a set index (grass/stone have 3; water/wood have 1 atm)
;	3. if the slot is the "centre" (fully surrounded), optionally
;		swap to a variants-strip slot for some interior noise
;	4. add the set base + (local_row * ATLAS_COLS + local_col)
;	5. for water, advance the base by frame * 4 rows
;
; the slot returned is a global atlas index
;----------------------------------------------------------------
; in:	edi = tx, esi = ty, edx = tile id (autotile type)
; out:	eax = atlas slot
;================================================================
autotile_pick_slot:
	push rbx
	push r12
	push r13
	push r14
	push r15
	; 5 callee-saves + ret = 48, 16-aligned

	mov ebx, edi			; tx
	mov r12d, esi			; ty
	mov r13d, edx			; tile id

	; --- pick set ---
	cmp r13d, TILE_GRASS
	je .sc_grass_set
	cmp r13d, TILE_STONE
	je .sc_stone_set
	; water + wood walls: set 0
	xor r14d, r14d
	jmp .have_set
.sc_grass_set:
	mov edi, ebx
	mov esi, r12d
	call autotile_hash
	mov ecx, GRASS_SET_COUNT
	xor edx, edx
	div ecx
	mov r14d, edx			; r14d = chosen set index
	jmp .have_set
.sc_stone_set:
	mov edi, ebx
	mov esi, r12d
	call autotile_hash
	mov ecx, STONE_SET_COUNT
	xor edx, edx
	div ecx
	mov r14d, edx
.have_set:

	; --- compute blob slot 0..46 ---
	mov edi, ebx
	mov esi, r12d
	mov edx, r13d
	call autotile_blob_mask	; eax = slot 0..46
	mov r15d, eax			; r15d = blob slot

	; --- variants-strip swap for the "fully surrounded" case ---
	; swap to one of VARIANT_COUNT variant slots in cols 12..15 of
	; the set's 4-row band
	cmp r15d, BLOB_SLOT_CENTRE
	jne .normal_slot
	; for wood walls we use the per-cell rolled object_variant byte
	; instead of position hash, so adjacent walls don't end up with
	; predictable parity patterns
	cmp r13d, TILE_WOOD_WALL
	je .variant_from_cell
	mov edi, ebx
	mov esi, r12d
	call autotile_hash
	jmp .have_variant_hash
.variant_from_cell:
	mov ecx, r12d
	imul ecx, MAP_WIDTH
	add ecx, ebx
	lea rdx, [object_variant]
	movzx eax, byte [rdx + rcx]
.have_variant_hash:
	; hash -> variant index in 0..VARIANT_COUNT-1
	mov ecx, VARIANT_COUNT
	xor edx, edx
	div ecx
	; variant index now in edx.  variants are laid out row-major
	; across 4 cols x 4 rows starting at col 12 of the set's top
	; row.  variant V -> col 12 + (V%4), local row V/4
	mov edi, edx
	and edi, VARIANT_COLS - 1	; col offset 0..3 (VARIANT_COLS=4)
	add edi, BLOB_COLS			; col 12..15
	shr edx, 2					; local row 0..3
	; offset = local_row * ATLAS_COLS + col
	imul edx, ATLAS_COLS
	add edx, edi
	mov r15d, edx				; r15d = atlas-relative slot offset
	jmp .add_base

.normal_slot:
	; blob slot 0..46.  convert to local atlas offset:
	;	local_row = slot / BLOB_COLS  (0..3)
	;	local_col = slot % BLOB_COLS  (0..11)
	;	offset    = local_row * ATLAS_COLS + local_col
	mov eax, r15d
	xor edx, edx
	mov ecx, BLOB_COLS
	div ecx					; eax = local_row, edx = local_col
	imul eax, ATLAS_COLS
	add eax, edx
	mov r15d, eax			; r15d = atlas-relative slot offset

.add_base:
	; --- add set base + (water frame offset for TILE_WATER) ---
	cmp r13d, TILE_GRASS
	je .base_grass
	cmp r13d, TILE_STONE
	je .base_stone
	cmp r13d, TILE_WATER
	je .base_water
	cmp r13d, TILE_WOOD_WALL
	je .base_wood
	; catch unknowns - return offset as-is (won't crash, just wrong)
	mov eax, r15d
	jmp .out
.base_grass:
	movzx eax, word [grass_set_bases + r14*2]
	add eax, r15d
	jmp .out
.base_stone:
	movzx eax, word [stone_set_bases + r14*2]
	add eax, r15d
	jmp .out
.base_water:
	; 4anim frames:
	; frame index = (tile_anim_ticks / WATER_ANIM_PERIOD) % 4
	movzx eax, word [water_set_base]
	add eax, r15d
	push rax
	mov eax, [tile_anim_ticks]
	mov ecx, WATER_ANIM_PERIOD
	xor edx, edx
	div ecx
	and eax, WATER_FRAME_COUNT - 1	; frame index 0..3
	imul eax, AUTOTILE_SET_ROWS * ATLAS_COLS
	mov ecx, eax
	pop rax
	add eax, ecx
	jmp .out
.base_wood:
	movzx eax, word [wood_wall_set_base]
	add eax, r15d
.out:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; nonauto_pick_slot
;----------------------------------------------------------------
; non-autotiled GROUND tile id -> atlas slot.  identity for most
; types, but a few use variant packs picked by position hash:
;	TILE_DIRT		- 8 ground variants (opaque soil) in row 1
;	TILE_WOOD_FLOOR - 4 variants in row 2 cols 8..11
;	TILE_TREE		- 4 variants in row 0 cols 12..15
;
; called by draw_tilemap - the ground-layer renderer.  for the
; OBJECT layer's dispatch, see nonauto_pick_slot_object below
;----------------------------------------------------------------
; in:	edi = tx, esi = ty, edx = tile id
; out:	eax = atlas slot
;================================================================
nonauto_pick_slot:
	cmp edx, TILE_DIRT
	je .dirt_ground
	cmp edx, TILE_WOOD_FLOOR
	je .wood_floor
	cmp edx, TILE_TREE
	je .tree
	; default - read base from the table
	lea rcx, [tile_atlas_base]
	movzx eax, byte [rcx + rdx]
	ret
.dirt_ground:
	; opaque soil variants for cave floors/excavaated areas
	push rdx
	call autotile_hash
	pop rdx
	and eax, DIRT_GROUND_VARIANT_COUNT - 1
	add eax, ATLAS_DIRT_GROUND_VARIANTS
	ret
.wood_floor:
	push rdx
	call autotile_hash
	pop rdx
	and eax, WOOD_FLOOR_VARIANT_COUNT - 1
	add eax, ATLAS_WOOD_FLOOR_VARIANTS
	ret
.tree:
	push rdx
	call autotile_hash
	pop rdx 
	and eax, TREE_VARIANT_COUNT - 1
	add eax, ATLAS_TREE_VARIANTS
	ret

;================================================================
; nonauto_pick_slot_object
;----------------------------------------------------------------
; OBJECT-layer variant of the picker.  kept around as a
; symbol so callers don't need to know whether the picker behaves
; differently per layer; if I add back per-layer differences again,
; the dispatch already lives here
;----------------------------------------------------------------
; in:	edi = tx, esi = ty, edx = object id
; out:	eax = atlas slot
;================================================================
nonauto_pick_slot_object:
	jmp nonauto_pick_slot

;================================================================
; init_tilemap_test: fill map with a test pattern
; NOT IN USE
;================================================================
init_tilemap_test:
	push rbx
	push r12		; y
	push r13		; x

	xor r12d, r12d	; y=0
.y_loop:
	cmp r12d, MAP_HEIGHT
	jge .done

	xor r13d, r13d	; x=0
.x_loop:
	cmp r13d, MAP_WIDTH
	jge .x_done

	mov eax, TILE_GRASS	;default tile

	;stone edges
	test r13d, r13d
	jz .pick_stone
	test r12d, r12d
	jz .pick_stone
	cmp r13d, MAP_WIDTH-1
	je .pick_stone
	cmp r12d, MAP_HEIGHT-1
	je .pick_stone

	;water blob
	cmp r13d, 16
	jl .check_dirt
	cmp r13d, 22
	jg .check_dirt
	cmp r12d, 12
	jl .check_dirt
	cmp r12d, 16
	jg .check_dirt
	mov eax, TILE_WATER
	jmp .write

.check_dirt:
	mov r14, rax		; save tile
	call rng_next
	and eax, 7
	jnz .keep_grass
	mov rax, r14
	mov eax, TILE_DIRT
	jmp .write
	
.keep_grass:
	mov rax, r14
	jmp .write

.pick_dirt:
	mov eax, TILE_DIRT
	jmp .write

.pick_stone:
	mov eax, TILE_STONE
	jmp .write

.pick_water:
	mov eax, TILE_WATER
	jmp .write

.write:
	; tilemap[y * MAP_WIDTH + x] = tile_id
	mov ecx, r12d
	imul ecx, MAP_WIDTH
	add ecx, r13d
	lea rbx, [tilemap]
	mov [rbx + rcx], al

	inc r13d
	jmp .x_loop
.x_done:
	inc r12d
	jmp .y_loop
.done:
	pop r13
	pop r12
	pop rbx
	ret

;================================================================
; draw_tilemap: render visible map to the framebuffer (+1 margin)
;----------------------------------------------------------------
; per visible tile: dispatches to autotile_pick_slot for the
; auto-types, otherwise nonauto_pick_slot.  the resulting slot
; is converted to (src_x, src_y) and blitted
;----------------------------------------------------------------
; in: rdi = ptr to texture struct (the atlas)
;================================================================
draw_tilemap:
	push rbp
	mov rbp, rsp
	sub rsp, 48
	push rbx
	push r12
	push r13
	push r14
	push r15

	; locals:
	;	[rbp-4]		ty
	;	[rbp-8]		tx
	;	[rbp-16]	atlas tex ptr (saved)
	;	[rbp-20]	ty_min
	;	[rbp-24]	ty_max (exclusive)
	;	[rbp-28]	tx_min
	;	[rbp-32]	tx_max (exclusive)

	mov [rbp-16], rdi

	; tx_min = max(0, camera_x / TILE_SIZE - 1)
	mov eax, [camera_x]
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	test edx, edx
	jns .tx_min_ok
	dec eax
.tx_min_ok:
	dec eax					; one-tile margin
	test eax, eax
	jns .tx_min_clamped
	xor eax, eax
.tx_min_clamped:
	mov [rbp-28], eax

	; tx_max = min(MAP_WIDTH, (camera_x + WINDOW_W) / TILE_SIZE + 2)
	mov eax, [camera_x]
	add eax, WINDOW_W
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	add eax, 2				; round-up + margin
	cmp eax, MAP_WIDTH
	jle .tx_max_ok
	mov eax, MAP_WIDTH
.tx_max_ok:
	mov [rbp-32], eax

	; ty_min / ty_max, same logic
	mov eax, [camera_y]
	cdq
	idiv ecx
	test edx, edx
	jns .ty_min_ok
	dec eax
.ty_min_ok:
	dec eax
	test eax, eax
	jns .ty_min_clamped
	xor eax, eax
.ty_min_clamped:
	mov [rbp-20], eax

	mov eax, [camera_y]
	add eax, WINDOW_H
	cdq
	idiv ecx
	add eax, 2
	cmp eax, MAP_HEIGHT
	jle .ty_max_ok
	mov eax, MAP_HEIGHT
.ty_max_ok:
	mov [rbp-24], eax

	; outer/inner loops
	mov eax, [rbp-20]
	mov [rbp-4], eax
.row:
	mov eax, [rbp-4]
	cmp eax, [rbp-24]
	jge .done

	mov eax, [rbp-28]
	mov [rbp-8], eax
.col:
	mov eax, [rbp-8]
	cmp eax, [rbp-32]
	jge .next_row

	; tile_id -> r12d
	mov eax, [rbp-4]
	imul eax, MAP_WIDTH
	add eax, [rbp-8]
	lea rbx, [tilemap]
	movzx r12d, byte [rbx + rax]

	; --- dispatch: autotile or static lookup ---
	mov eax, r12d
	call tile_is_autotiled
	test eax, eax
	jz .static_pick
	; autotile path
	mov edi, [rbp-8]
	mov esi, [rbp-4]
	mov edx, r12d
	call autotile_pick_slot
	jmp .have_slot
.static_pick:
	mov edi, [rbp-8]
	mov esi, [rbp-4]
	mov edx, r12d
	call nonauto_pick_slot
.have_slot:
	mov r13d, eax			; r13d = atlas slot

	; blit_texture_rect(rdi=tex, esi=src_x, edx=src_y, ecx=src_w,
	;					r8d=src_h, r9d=dst_x,
	;					[stack:dst_y], [stack:flip])
	mov rdi, [rbp-16]
	mov eax, r13d
	xor edx, edx
	mov ecx, ATLAS_COLS
	div ecx					; eax = row, edx = col
	imul edx, TILE_SIZE
	imul eax, TILE_SIZE
	mov esi, edx			; src_x
	mov edx, eax			; src_y
	mov ecx, TILE_SIZE
	mov r8d, TILE_SIZE
	mov r9d, [rbp-8]
	imul r9d, TILE_SIZE
	sub r9d, [camera_x]		; dst_x

	mov eax, [rbp-4]
	imul eax, TILE_SIZE
	sub eax, [camera_y]
	push 0					; flip
	push rax				; dst_y
	call blit_texture_rect
	add rsp, 16

	; --- flower overlay on grass ---
	; some % of grass tiles get a small flower decoration on top.
	; the chance is FLOWER_CHANCE_NUM/FLOWER_CHANCE_DEN; if it
	; lands, the variant 0..7 is picked by re-hashing with a salt
	; to twist from the chance test.  flowers are blit with
	; the magenta colour key so the grass shows around them
	cmp r12d, TILE_GRASS
	jne .no_flower
	mov edi, [rbp-8]
	mov esi, [rbp-4]
	call autotile_hash
	; chance test: low byte of hash vs FLOWER_CHANCE_NUM
	mov ecx, eax
	and ecx, FLOWER_CHANCE_DEN - 1	; 0..255 (DEN=256, ^2)
	cmp ecx, FLOWER_CHANCE_NUM
	jge .no_flower
	; lands - pick variant from upper hash bits to twist
	shr eax, 8
	and eax, FLOWER_VARIANT_COUNT - 1
	add eax, ATLAS_FLOWER_VARIANTS
	mov r13d, eax			; r13d = flower slot

	; slot -> src_x, src_y
	mov rdi, [rbp-16]
	mov eax, r13d
	xor edx, edx
	mov ecx, ATLAS_COLS
	div ecx
	imul edx, TILE_SIZE
	imul eax, TILE_SIZE
	mov esi, edx			; src_x
	mov edx, eax			; src_y
	mov ecx, TILE_SIZE
	mov r8d, TILE_SIZE
	mov r9d, [rbp-8]
	imul r9d, TILE_SIZE
	sub r9d, [camera_x]		; dst_x
	mov eax, [rbp-4]
	imul eax, TILE_SIZE
	sub eax, [camera_y]		; dst_y in eax
	mov r10, 0xFFFF00FF		; magenta key
	push r10
	push 0					; flip
	push rax				; dst_y
	call blit_texture_rect_keyed
	add rsp, 24
.no_flower:

	inc dword [rbp-8]
	jmp .col
.next_row:
	inc dword [rbp-4]
	jmp .row
.done:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	leave
	ret

;================================================================
; draw_objects (pre)
;----------------------------------------------------------------
; second-pass renderer for the object overlay layer.  same loop
; structure as draw_tilemap but reads from objectmap, skips
; OBJ_NONE cells, and blits with a magenta colour key so the
; ground (drawn by draw_tilemap) shows through transparent
; pixels of the object sprite
;
; objects are routed through the same slot-pickers as ground:
;   - OBJ_WOOD_WALL -> autotile_pick_slot (matches in objectmap)
;   - everything else (trees, doors, bed, chair) -> nonauto path
;----------------------------------------------------------------
; in: rdi = ptr to atlas texture
;================================================================

;================================================================
; is_tall_object: how does this tile y-sort with entities?
;----------------------------------------------------------------
; classification:
;	0 = FLAT		- drawn in the normal object pass, under all
;					entities (empty/doors/beds/chairs/torches/etc)
;	1 = TREE		- y-sort with entities using tile-top as the
;					sort key (ty*TILE_SIZE).  player to the side of
;					a tree at the same tile y is drawn in front,
;					walking under the leaves. looks great!
;	2 = WALL_BOTTOM	- y-sort with entities at midline
;					(ty*TILE_SIZE + TILE_SIZE/2) so entities
;					crossing the 50% line flip in front
;	3 = WALL_TALL	- always above entities (sort key beyond any 
;					possible entity y).  used for walls that aren't
;					the south end of a run - their art sticks UP the
;					full tile height so they should occlude anyone
;					they overlap
;
; wall rule: BOTTOM iff the south neighbour is not the same wall.
; that covers every autotile slot whose artwork shows a ground
; attachment at the bottom edge - isolated stones, horizontal-
; only runs (the "first 4 of the last wang row"), and the south
; end of any vertical run.  walls with a wall directly south of
; them have their bottom flush against more wall and stick up
; the full tile height
;----------------------------------------------------------------
; in:	edi = tx, esi = ty, edx = object id
; out:	eax = 0/1/2/3 (FLAT / TREE / WALL_BOTTOM / WALL_TALL)
;================================================================
is_tall_object:
	cmp edx, OBJ_TREE
	je .tree

	cmp edx, OBJ_STONE_WALL
	je .wall
	cmp edx, OBJ_WOOD_WALL
	je .wall

	; everything else - doors, beds, chairs, torches - is flat
	xor eax, eax
	ret

.wall:
	; S not a wall -> bottom-most, else tall
	push rbx
	push r12
	push r13
	mov ebx, edi			; tx
	mov r12d, esi			; ty
	mov r13d, edx			; obj id

	mov edi, ebx
	mov esi, r12d
	inc esi					; ty+1
	mov edx, r13d
	call autotile_match_at
	test eax, eax
	jnz .wall_tall			; S is same wall -> tall

	; S not wall -> bottom-most
	mov eax, 2
	pop r13
	pop r12
	pop rbx
	ret

.wall_tall:
	mov eax, 3
	pop r13
	pop r12
	pop rbx
	ret

.tree:
	mov eax, 1
	ret

;================================================================
; draw_objects
;================================================================
draw_objects:
	push rbp
	mov rbp, rsp
	sub rsp, 48
	push rbx
	push r12
	push r13
	push r14
	push r15

	; locals (mirror draw_tilemap):
	;	[rbp-4]  ty
	;	[rbp-8]  tx
	;	[rbp-16] atlas tex ptr
	;	[rbp-20] ty_min
	;	[rbp-24] ty_max
	;	[rbp-28] tx_min
	;	[rbp-32] tx_max

	mov [rbp-16], rdi

	; tx_min = max(0, camera_x / TILE_SIZE - 1)
	mov eax, [camera_x]
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	; floor for negatives - shouldn't happen post-clamp hopefully
	test edx, edx
	jns .tx_min_ok
	dec eax
.tx_min_ok:
	dec eax					; one-tile margin
	test eax, eax
	jns .tx_min_clamped
	xor eax, eax
.tx_min_clamped:
	mov [rbp-28], eax

	; tx_max = min(MAP_WIDTH, (camera_x + WINDOW_W) / TILE_SIZE + 2)
	mov eax, [camera_x]
	add eax, WINDOW_W
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	add eax, 2				; round-up + margin
	cmp eax, MAP_WIDTH
	jle .tx_max_ok
	mov eax, MAP_WIDTH
.tx_max_ok:
	mov [rbp-32], eax

	; ty_min / ty_max, same logic
	mov eax, [camera_y]
	cdq
	idiv ecx
	test edx, edx
	jns .ty_min_ok
	dec eax
.ty_min_ok:
	dec eax
	test eax, eax
	jns .ty_min_clamped
	xor eax, eax
.ty_min_clamped:
	mov [rbp-20], eax

	mov eax, [camera_y]
	add eax, WINDOW_H
	cdq
	idiv ecx
	add eax, 2
	cmp eax, MAP_HEIGHT
	jle .ty_max_ok
	mov eax, MAP_HEIGHT
.ty_max_ok:
	mov [rbp-24], eax

	; outer/inner loops
	mov eax, [rbp-20]
	mov [rbp-4], eax
.row:
	mov eax, [rbp-4]
	cmp eax, [rbp-24]
	jge .done

	mov eax, [rbp-28]
	mov [rbp-8], eax
.col:
	mov eax, [rbp-8]
	cmp eax, [rbp-32]
	jge .next_row

	; obj_id -> r12d, skip empty cells (OBJ_NONE = 0)
	mov eax, [rbp-4]
	imul eax, MAP_WIDTH
	add eax, [rbp-8]
	lea rbx, [objectmap]
	movzx r12d, byte [rbx + rax]
	test r12d, r12d
	jz .next_col

	; skip tall objects in this pass - they'll be drawn later by
	; draw_tall_objects so they always appear in front of entities
	mov edi, [rbp-8]
	mov esi, [rbp-4]
	mov edx, r12d
	call is_tall_object
	test eax, eax
	jnz .next_col

	; --- dispatch: walls (stone & wood) are autotiled, others
	; are static.  with the blob system stone walls no longer
	; need a special "bottom-edge" path - blob has dedicated
	; slots for every wall configuration (1-wide strips, isolated
	; tiles, south-facing edges, etc) so we just route both wall
	; kinds through autotile_pick_slot
	cmp r12d, OBJ_WOOD_WALL
	je .auto_obj
	cmp r12d, OBJ_STONE_WALL
	je .auto_obj

	; torch uses animated frame from row 3
	cmp r12d, OBJ_TORCH
	je .torch_obj

	; static path - look up tree/door/bed/chair slot.  uses the
	; object-layer picker, which currently just aliases to the
	; ground picker; the indirection's kept for future per-layer
	; differences without callers needing to change
	mov edi, [rbp-8]
	mov esi, [rbp-4]
	mov edx, r12d
	call nonauto_pick_slot_object
	jmp .have_slot

.torch_obj:
	; pass tile coords for anim start offset
	mov edi, [rbp-8]
	mov esi, [rbp-4]
	call torch_atlas_slot
	jmp .have_slot

.auto_obj:
	mov edi, [rbp-8]
	mov esi, [rbp-4]
	mov edx, r12d
	call autotile_pick_slot
.have_slot:
	mov r13d, eax			; r13d = atlas slot

	; convert slot -> src_x, src_y in pixels
	mov rdi, [rbp-16]
	mov eax, r13d
	xor edx, edx
	mov ecx, ATLAS_COLS
	div ecx					; eax = row, edx = col
	imul edx, TILE_SIZE
	imul eax, TILE_SIZE
	mov esi, edx			; src_x
	mov edx, eax			; src_y
	mov ecx, TILE_SIZE		; src_w
	mov r8d, TILE_SIZE		; src_h
	mov r9d, [rbp-8]
	imul r9d, TILE_SIZE
	sub r9d, [camera_x]		; dst_x

	; blit_texture_rect_keyed takes the same args as the plain
	; blit, plus a colour key at [rbp+32] (= 3rd stack arg).  push
	; in reverse: key, flip, dst_y.  the magenta constant goes
	; via a register because `push imm32` sign-extends and NASM
	; warns about 0xFFFF00FF
	mov eax, [rbp-4]
	imul eax, TILE_SIZE
	sub eax, [camera_y]
	mov r10, 0xFFFF00FF		; magenta ARGB - colour key
	push r10
	push 0					; flip
	push rax				; dst_y
	call blit_texture_rect_keyed
	add rsp, 24

.next_col:
	inc dword [rbp-8]
	jmp .col
.next_row:
	inc dword [rbp-4]
	jmp .row
.done:
	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	leave
	ret

;================================================================
; collect_visible_tall_tiles: build the y-sorted tall tile list
;----------------------------------------------------------------
; scans the visible tile region (same bounds as draw_objects) row
; by row and records every tall object cell into tall_tile_list[].
; because the scan is row-major, the resulting list is alreaddy
; sorted ascending by ty - any ties (same row) sit next to each
; other and can be drawn in any order since they don't overlap
;
; consumed during draw_entities, where each visible tall tile is
; emitted just before the first entity whose y >= tile-top-y, so
; the player & tall objects end up properly..interleaved? without
; running an actual merge sort
;----------------------------------------------------------------
; in:	(no args; reads camera_x/y, objectmap)
; out:	tall_tile_list filled, tall_tile_count = entry count
;================================================================
collect_visible_tall_tiles:
	push rbp
	mov rbp, rsp
	sub rsp, 48
	push rbx
	push r12
	push r13
	push r14
	push r15

	; locals:
	;	[rbp-4]  ty		[rbp-8]  tx
	;	[rbp-12] count	(also written to tall_tile_count at exit)
	;	[rbp-20] ty_min	[rbp-24] ty_max
	;	[rbp-28] tx_min	[rbp-32] tx_max

	; bounds - same clamp logic as draw_objects
	mov eax, [camera_x]
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	test edx, edx
	jns .ct_tx_min_ok
	dec eax
.ct_tx_min_ok:
	dec eax
	test eax, eax
	jns .ct_tx_min_clamped
	xor eax, eax
.ct_tx_min_clamped:
	mov [rbp-28], eax

	mov eax, [camera_x]
	add eax, WINDOW_W
	cdq
	mov ecx, TILE_SIZE
	idiv ecx
	add eax, 2
	cmp eax, MAP_WIDTH
	jle .ct_tx_max_ok
	mov eax, MAP_WIDTH
.ct_tx_max_ok:
	mov [rbp-32], eax

	mov eax, [camera_y]
	cdq
	idiv ecx
	test edx, edx
	jns .ct_ty_min_ok
	dec eax
.ct_ty_min_ok:
	dec eax
	test eax, eax
	jns .ct_ty_min_clamped
	xor eax, eax
.ct_ty_min_clamped:
	mov [rbp-20], eax

	mov eax, [camera_y]
	add eax, WINDOW_H
	cdq
	idiv ecx
	add eax, 2
	cmp eax, MAP_HEIGHT
	jle .ct_ty_max_ok
	mov eax, MAP_HEIGHT
.ct_ty_max_ok:
	mov [rbp-24], eax

	xor r14d, r14d; count = 0

	mov eax, [rbp-20]
	mov [rbp-4], eax
.ct_row:
	mov eax, [rbp-4]
	cmp eax, [rbp-24]
	jge .ct_done

	mov eax, [rbp-28]
	mov [rbp-8], eax
.ct_col:
	mov eax, [rbp-8]
	cmp eax, [rbp-32]
	jge .ct_next_row

	; obj_id, skip empty
	mov eax, [rbp-4]
	imul eax, MAP_WIDTH
	add eax, [rbp-8]
	mov r12d, eax	; r12 = cell index
	lea rbx, [objectmap]
	movzx r13d, byte [rbx + r12]
	test r13d, r13d
	jz .ct_next_col

	; classify: 0=flat (skip), 1=tree (sort_y=ty*16),
	; 2=wall_bottom (sort_y=ty*16+8), 3=wall_tall (sort_y=0xFFFF
	; = always after all entities).  pack (sort_y<<16) | cell
	mov edi, [rbp-8]
	mov esi, [rbp-4]
	mov edx, r13d
	call is_tall_object
	test eax, eax
	jz .ct_next_col

	cmp eax, 3
	je .ct_sorty_tall

	; tree (1) or wall_bottom (2): sort_y = ty*TILE_SIZE
	; (plus TILE_SIZE/2 when bottom)
	mov ecx, [rbp-4]
	imul ecx, TILE_SIZE
	cmp eax, 2
	jne .ct_have_sorty
	add ecx, TILE_SIZE / 2
	jmp .ct_have_sorty

.ct_sorty_tall:
	; tall walls are "always above" - pick a sort_y larger than
	; any entity could ever have:
	mov ecx, 0xFFFF

.ct_have_sorty:
	; record into list (skip if at cap).  packed entry: sort_y in
	; high 16 bits, cell index in low 16 bits
	cmp r14d, TALL_TILE_MAX
	jge .ct_next_col
	shl ecx, 16
	or ecx, r12d					; ecx = packed entry
	lea rbx, [tall_tile_list]
	mov [rbx + r14*4], ecx
	inc r14d

	; bubble back: within a row, tall (sort_y=ty*16) and bottom-
	; most (sort_y=ty*16+8) can land out of order depending on
	; left-to-right scan.  swap with the previous entry while it's
	; greater using UNSIGNED compare since these packed values
	; (sort_y 0xFFFF in high half) look negative as signed 32-bit
	mov edx, r14d
	dec edx						; edx = idx we just wrote
.ct_bubble:
	cmp edx, 0
	jle .ct_bubble_done
	mov esi, [rbx + rdx*4]		; current
	mov edi, [rbx + rdx*4 - 4]	; previous
	cmp edi, esi				; unsigned: sort_y dominates
	jbe .ct_bubble_done			; prev <= current, in order
	mov [rbx + rdx*4 - 4], esi
	mov [rbx + rdx*4], edi
	dec edx
	jmp .ct_bubble
.ct_bubble_done:

.ct_next_col:
	inc dword [rbp-8]
	jmp .ct_col
.ct_next_row:
	inc dword [rbp-4]
	jmp .ct_row
.ct_done:
	mov [tall_tile_count], r14d

	pop r15
	pop r14
	pop r13
	pop r12
	pop rbx
	leave
	ret

;================================================================
; draw_tall_tile_one_idx: draw one tile from tall_tile_list
;----------------------------------------------------------------
; full-tile blit (not the half overlay) using whichever picker
; matches the object type
; same dispatch as draw_objects
;----------------------------------------------------------------
; in:	edi = list index into tall_tile_list (0..tall_tile_count-1)
;		rsi = atlas texture ptr
;================================================================
draw_tall_tile_one_idx:
	push rbp
	mov rbp, rsp
	push rbx
	push r12
	push r13
	sub rsp, 24	; locals; 3 pushes + 24 keeps rsp 16-aligned at calls

	; locals (rsp-relative; saved regs sit between these and rbp):
	;	[rsp+0]   atlas tex ptr
	;	[rsp+8]   ty
	;	[rsp+12]  tx

	mov [rsp+0], rsi			; atlas tex

	; cell index from the list (entries are packed: sort_y high
	; 16 bits, cell low 16 bits - mask off the sort_y)
	lea rax, [tall_tile_list]
	mov eax, [rax + rdi*4]		; packed entry
	movzx eax, ax				; cell = low 16 bits
	; tx = cell % MAP_WIDTH, ty = cell / MAP_WIDTH
	xor edx, edx
	mov ecx, MAP_WIDTH
	div ecx
	mov [rsp+8], eax			; ty
	mov [rsp+12], edx			; tx

	; obj id at this cell
	mov eax, [rsp+8]
	imul eax, MAP_WIDTH
	add eax, [rsp+12]
	lea rbx, [objectmap]
	movzx r12d, byte [rbx + rax]

	; dispatch to picker
	cmp r12d, OBJ_WOOD_WALL
	je .dt_auto
	cmp r12d, OBJ_STONE_WALL
	je .dt_auto

	; trees/future tall non-auto types go via the nonauto picker,
	; same as draw_objects
	mov edi, [rsp+12]
	mov esi, [rsp+8]
	mov edx, r12d
	call nonauto_pick_slot_object
	jmp .dt_have_slot

.dt_auto:
	mov edi, [rsp+12]
	mov esi, [rsp+8]
	mov edx, r12d
	call autotile_pick_slot
.dt_have_slot:
	mov r13d, eax; slot

	; slot -> src_x, src_y in atlas pixels
	mov rdi, [rsp+0]
	mov eax, r13d
	xor edx, edx
	mov ecx, ATLAS_COLS
	div ecx
	imul edx, TILE_SIZE
	imul eax, TILE_SIZE
	mov esi, edx				; src_x
	mov edx, eax				; src_y
	mov ecx, TILE_SIZE			; src_w
	mov r8d, TILE_SIZE			; src_h
	mov r9d, [rsp+12]
	imul r9d, TILE_SIZE
	sub r9d, [camera_x]			; dst_x

	mov eax, [rsp+8]
	imul eax, TILE_SIZE
	sub eax, [camera_y]			; dst_y
	mov r10, 0xFFFF00FF
	push r10
	push 0						; flip
	push rax					; dst_y
	call blit_texture_rect_keyed
	add rsp, 24

	add rsp, 24
	pop r13
	pop r12
	pop rbx
	pop rbp
	ret

%endif
