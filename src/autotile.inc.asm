; autotile.inc.asm - wang tiles/autotiles/automap/whatever the name
;
; reference layout and bitmasks from here:
; https://www.boristhebrave.com/permanent/24/06/cr31/stagecast/wang/blob.html
;
; for each tile we look at all 8 surrounding neighbours and form
; an 8-bit raw mask, with weights (clockwise from north):
;	N=1  NE=2  E=4  SE=8  S=16  SW=32  W=64  NW=128
;
; then normalise: a diagonal bit only "counts" if both of its
; adjacent cardinal bits also count.  eg NE only matters if both
; N and E match - otherwise that corner is an outside corner of the
; blob and the diagonal neighbour can't influence the visual
;
; that collapses 2^8 = 256 raw states down to 47 unique cases
; we look them up in a 256-entry table that maps raw_mask->slot 0..46
;
; i'm not sure what this specific layout is called, not named on the
; above link. its also the one Godot uses and seemed like the nicest
; minimal layout for making the tile art with
;
; mapping from slot index to represented mask is sorted by raw mask
; value ascending, slots are row major within the block. 
;	slot 0  = mask 0x00 (fully isolated tile, no neighbours match)
;	slot 46 = mask 0xFF (fully surrounded, all 8 match)
; and everything inbetween.  see table comment somewhere below for
; full listing, or just refere to the pixel art!
;
; ----- variants -----
; each autotile set can have variants, picked by deterministic
; positional hashes.  + extra 4x4 for the 'fully surrounded' tiles,
; prob way too many, but whatever, rounds the tilesheet dims nicely
;
; ----- water animation -----
; water occupies multiple set stacked vertically, 1x4 atm
; the picker advances the base-row by frame index at draw time

%ifndef AUTOTILE_INC
%define AUTOTILE_INC

; corner/edge bit weights (clockwise from north)
%define BLOB_N	1
%define BLOB_NE	2
%define BLOB_E	4
%define BLOB_SE	8
%define BLOB_S	16
%define BLOB_SW	32
%define BLOB_W	64
%define BLOB_NW	128

; the slot reserved for "fully surrounded" (raw mask 0xFF)
%define BLOB_SLOT_CENTRE	33

section .data
	; -----------------------------------------------------------
	; blob lookup: raw 8-bit neighbour mask -> slot 0..47
	; 
	; row 0 (slots 0..11): 16,0,84,80,213,92,116,87,28,125,124,112
	; row 1 (slots 12..23):17,21,85,81,29,127,253,113,31,119,-,245
	; row 2 (slots 24..35):1,5,69,65,23,223,247,209,95,255,221,241
	; row 3 (slots 36..47):0,4,68,64,117,71,197,93,7,199,215,193
	;
	; slot 22 (1,10) is redundant. picker shoul never land there
	; -----------------------------------------------------------
	align 1
	blob_raw_to_slot: ; generated with a handy python script:
	; 0x00..0x0F
	db 36, 24, 36, 24, 37, 25, 37, 44, 36, 24, 36, 24, 37, 25, 37, 44
	; 0x10..0x1F
	db  0, 12,  0, 12,  1, 13,  1, 28,  0, 12,  0, 12,  8, 16,  8, 20
	; 0x20..0x2F
	db 36, 24, 36, 24, 37, 25, 37, 44, 36, 24, 36, 24, 37, 25, 37, 44
	; 0x30..0x3F
	db  0, 12,  0, 12,  1, 13,  1, 28,  0, 12,  0, 12,  8, 16,  8, 20
	; 0x40..0x4F
	db 39, 27, 39, 27, 38, 26, 38, 41, 39, 27, 39, 27, 38, 26, 38, 41
	; 0x50..0x5F
	db  3, 15,  3, 15,  2, 14,  2,  7,  3, 15,  3, 15,  5, 43,  5, 32
	; 0x60..0x6F
	db 39, 27, 39, 27, 38, 26, 38, 41, 39, 27, 39, 27, 38, 26, 38, 41
	; 0x70..0x7F
	db 11, 19, 11, 19,  6, 40,  6, 21, 11, 19, 11, 19, 10,  9, 10, 17
	; 0x80..0x8F
	db 36, 24, 36, 24, 37, 25, 37, 44, 36, 24, 36, 24, 37, 25, 37, 44
	; 0x90..0x9F
	db  0, 12,  0, 12,  1, 13,  1, 28,  0, 12,  0, 12,  8, 16,  8, 20
	; 0xA0..0xAF
	db 36, 24, 36, 24, 37, 25, 37, 44, 36, 24, 36, 24, 37, 25, 37, 44
	; 0xB0..0xBF
	db  0, 12,  0, 12,  1, 13,  1, 28,  0, 12,  0, 12,  8, 16,  8, 20
	; 0xC0..0xCF
	db 39, 47, 39, 47, 38, 42, 38, 45, 39, 47, 39, 47, 38, 42, 38, 45
	; 0xD0..0xDF
	db  3, 31,  3, 31,  2,  4,  2, 46,  3, 31,  3, 31,  5, 34,  5, 29
	; 0xE0..0xEF
	db 39, 47, 39, 47, 38, 42, 38, 45, 39, 47, 39, 47, 38, 42, 38, 45
	; 0xF0..0xFF
	db 11, 35, 11, 35,  6, 23,  6, 30, 11, 35, 11, 35, 10, 18, 10, 33

section .text

;================================================================
; autotile_match_at
;----------------------------------------------------------------
; does the tile at (tx, ty) match the "auto-group" of tile id (dl)?
;
; for autotiling, two tiles "match" if they have the same id
; out-of-bounds counts as non-matching
;
; matching layer depends on the type:
;	- OBJ_WOOD_WALL and OBJ_STONE_WALL live in the object overlay,
;	  so we look in objectmap for them
;	- everything else (grass/water) is a ground tile, so we look
;	  in tilemap
;----------------------------------------------------------------
; in:	edi = tx, esi = ty, dl = tile/object id to match
; out:	eax = 1 if matches, 0 otherwise
;================================================================
autotile_match_at:
	push rbx
	mov ebx, edx			; save match-target id
	; pick layer based on id - both wall types live in objectmap;
	; the other autotiled types (grass, water) are in tilemap
	;
	; literal values here are TILE_STONE=2 (= OBJ_STONE_WALL)
	; and TILE_WOOD_WALL=6 (=OBJ_WOOD_WALL).. hardcoding them
	; because autotile.inc is included before tilemap.inc and
	; the constants aren't yet visible at parse time
	cmp bl, 2				; TILE_STONE / OBJ_STONE_WALL
	je .from_object
	cmp bl, 6				; TILE_WOOD_WALL / OBJ_WOOD_WALL
	je .from_object
	call tile_at
	jmp .have_id
.from_object:
	call object_at
.have_id:
	cmp al, bl
	je .yes
	xor eax, eax
	pop rbx 
	ret
.yes:
	mov eax, 1
	pop rbx
	ret

;================================================================
; autotile_blob_mask
;----------------------------------------------------------------
; compute the 8-neighbour blob mask for tile (tx, ty) of type dl
; and look it up to a slot 0..46 in the blob raw->slot table
;----------------------------------------------------------------
; in:	edi = tx, esi = ty, edx = tile id (low byte)
; out:	eax = slot 0..46
;================================================================
autotile_blob_mask:
	push rbp
	mov rbp, rsp
	sub rsp, 32				; locals: see layout below
	push rbx
	push r12
	push r13
	; 1 rbp + 3 callee-saves + ret = 40 (8 mod 16), sub 32 keeps it
	; aligned for inner calls

	mov ebx, edi			; ebx = tx
	mov r12d, esi			; r12d = ty
	mov r13d, edx			; r13d = type id

	; stack scratch - 8 ints, 4 bytes each
	;	[rbp-4]  N  match
	;	[rbp-8]  NE match
	;	[rbp-12] E  match
	;	[rbp-16] SE match
	;	[rbp-20] S  match
	;	[rbp-24] SW match
	;	[rbp-28] W  match
	;	[rbp-32] NW match

	; --- N (tx, ty-1) ---
	mov edi, ebx
	mov esi, r12d
	dec esi
	mov edx, r13d
	call autotile_match_at
	mov [rbp-4], eax

	; --- NE (tx+1, ty-1) ---
	mov edi, ebx
	inc edi
	mov esi, r12d
	dec esi
	mov edx, r13d
	call autotile_match_at
	mov [rbp-8], eax

	; --- E (tx+1, ty) ---
	mov edi, ebx
	inc edi
	mov esi, r12d
	mov edx, r13d
	call autotile_match_at
	mov [rbp-12], eax

	; --- SE (tx+1, ty+1) ---
	mov edi, ebx
	inc edi
	mov esi, r12d
	inc esi
	mov edx, r13d
	call autotile_match_at
	mov [rbp-16], eax

	; --- S (tx, ty+1) ---
	mov edi, ebx
	mov esi, r12d
	inc esi
	mov edx, r13d
	call autotile_match_at
	mov [rbp-20], eax

	; --- SW (tx-1, ty+1) ---
	mov edi, ebx
	dec edi
	mov esi, r12d
	inc esi
	mov edx, r13d
	call autotile_match_at
	mov [rbp-24], eax

	; --- W (tx-1, ty) ---
	mov edi, ebx
	dec edi
	mov esi, r12d
	mov edx, r13d
	call autotile_match_at
	mov [rbp-28], eax

	; --- NW (tx-1, ty-1) ---
	mov edi, ebx
	dec edi
	mov esi, r12d
	dec esi
	mov edx, r13d
	call autotile_match_at
	mov [rbp-32], eax

	; build raw mask: N=1 NE=2 E=4 SE=8 S=16 SW=32 W=64 NW=128
	; we shift each match result (0/1) by its bit position and OR
	; into the accumulator
	xor eax, eax			; mask accumulator

	mov ecx, [rbp-4]		; N
	; bit 0 - no shift
	or eax, ecx

	mov ecx, [rbp-8]		; NE
	shl ecx, 1
	or eax, ecx

	mov ecx, [rbp-12]		; E
	shl ecx, 2
	or eax, ecx

	mov ecx, [rbp-16]		; SE
	shl ecx, 3
	or eax, ecx

	mov ecx, [rbp-20]		; S
	shl ecx, 4
	or eax, ecx

	mov ecx, [rbp-24]		; SW
	shl ecx, 5
	or eax, ecx

	mov ecx, [rbp-28]		; W
	shl ecx, 6
	or eax, ecx

	mov ecx, [rbp-32]		; NW
	shl ecx, 7
	or eax, ecx

	; eax now holds the raw 8-bit neighbour state, look it up to
	; get the canonical slot 0..46.  the table already absorbs the
	; normalisation step (irrelevant diagonals collapse to the same
	; slot as their no-diagonal variant)
	lea rcx, [blob_raw_to_slot]
	movzx eax, byte [rcx + rax]

	pop r13
	pop r12
	pop rbx
	leave
	ret

;================================================================
; autotile_hash
;----------------------------------------------------------------
; deterministic small-int hash of (tx, ty), used to pick a set
; or a variant slot pseudo-randomly without persisting state
;----------------------------------------------------------------
; in:	edi = tx, esi = ty
; out:	eax = unsigned 32-bit hash (caller takes % count)
;================================================================
autotile_hash:
	; cheap mix - (tx*73) xor (ty*31), then a final xorshift
	mov eax, edi
	imul eax, 73
	mov ecx, esi
	imul ecx, 31
	xor eax, ecx
	; xorshift to break up regular patterns
	mov ecx, eax
	shr ecx, 13
	xor eax, ecx
	imul eax, 2654435761; "knuth multiplicative hash" constant
	ret

%endif
