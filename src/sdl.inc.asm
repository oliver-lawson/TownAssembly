; extern decls for SDL funcs
; linking against libSDL2, linker will resolve them

%ifndef SDL_INC
%define SDL_INC

extern SDL_Init
extern SDL_Quit
extern SDL_CreateWindow
extern SDL_DestroyWindow
extern SDL_CreateRenderer
extern SDL_DestroyRenderer
extern SDL_CreateTexture
extern SDL_DestroyTexture
extern SDL_UpdateTexture
extern SDL_RenderClear
extern SDL_RenderCopy
extern SDL_RenderPresent
extern SDL_PollEvent
extern SDL_Delay
extern SDL_GetError

; sdl constants we need (from sdl headers, computed at runtime there)
; reference:
; https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL.h
; SDL_Init flags 
%define SDL_INIT_VIDEO              0x00000020
; https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL_video.h
; SDL_WindowFlags: 
%define SDL_WINDOWPOS_CENTERED      0x2FFF0000
%define SDL_WINDOW_SHOWN            0x00000004
; https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL_render.h
; SDL_RendererFlags:
%define SDL_RENDERER_ACCELERATED    0x00000002
%define SDL_RENDERER_PRESENTVSYNC   0x00000004
; SDL_TextureAccess:
%define SDL_TEXTUREACCESS_STREAMING 1
; https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL_pixels.h
; though it's bit-composed through a function there, seems to match
; the SDL3 version @ https://github.com/libsdl-org/SDL/blob/main/include/SDL3/SDL_pixels.h at least
%define SDL_PIXELFORMAT_ARGB8888    0x16362004

; event types
; https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL_events.h
; named SDL_QUIT, SDL_KEYDOWN there as the structs are SDL_QuitEvent, etc
%define SDL_QUIT_EVENT      0x100
%define SDL_KEYDOWN_EVENT   0x300

; scancodes.  using these instead of keycodes for size & no key repeat headache)
; https://github.com/libsdl-org/SDL/blob/SDL2/include/SDL_scancode.h
%define SCANCODE_LEFT       80
%define SCANCODE_RIGHT      79
%define SCANCODE_UP         82
%define SCANCODE_DOWN       81
%define SCANCODE_ESCAPE     41

; SDL_Event layout (we only care about the bits we use)
;   offset 0:  Uint32 type
;   offset 16: SDL_Scancode scancode (Uint32, in keysym)
; total size 56 bytes. we'll allocate 64 for alignment safety.
%define SDL_EVENT_TYPE_OFF      0
%define SDL_EVENT_SCANCODE_OFF  16
%define SDL_EVENT_SIZE          64

%endif