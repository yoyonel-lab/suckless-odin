#pragma once
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    IMGUIZMO_TRANSLATE_X = (1u << 0),
    IMGUIZMO_TRANSLATE_Y = (1u << 1),
    IMGUIZMO_TRANSLATE_Z = (1u << 2),
    IMGUIZMO_ROTATE_X    = (1u << 3),
    IMGUIZMO_ROTATE_Y    = (1u << 4),
    IMGUIZMO_ROTATE_Z    = (1u << 5),
    IMGUIZMO_ROTATE_SCREEN = (1u << 6),
    IMGUIZMO_SCALE_X     = (1u << 7),
    IMGUIZMO_SCALE_Y     = (1u << 8),
    IMGUIZMO_SCALE_Z     = (1u << 9),
    IMGUIZMO_BOUNDS      = (1u << 10),
    IMGUIZMO_SCALE_XU    = (1u << 11),
    IMGUIZMO_SCALE_YU    = (1u << 12),
    IMGUIZMO_SCALE_ZU    = (1u << 13),

    IMGUIZMO_TRANSLATE   = IMGUIZMO_TRANSLATE_X | IMGUIZMO_TRANSLATE_Y | IMGUIZMO_TRANSLATE_Z,
    IMGUIZMO_ROTATE      = IMGUIZMO_ROTATE_X | IMGUIZMO_ROTATE_Y | IMGUIZMO_ROTATE_Z | IMGUIZMO_ROTATE_SCREEN,
    IMGUIZMO_SCALE       = IMGUIZMO_SCALE_X | IMGUIZMO_SCALE_Y | IMGUIZMO_SCALE_Z,
    IMGUIZMO_SCALEU      = IMGUIZMO_SCALE_XU | IMGUIZMO_SCALE_YU | IMGUIZMO_SCALE_ZU,
    IMGUIZMO_UNIVERSAL   = IMGUIZMO_TRANSLATE | IMGUIZMO_ROTATE | IMGUIZMO_SCALEU
} ImGuizmo_Operation;

typedef enum {
    IMGUIZMO_LOCAL = 0,
    IMGUIZMO_WORLD = 1
} ImGuizmo_Mode;

void ImGuizmo_SetDrawlist(void* drawlist);
void ImGuizmo_BeginFrame(void);
void ImGuizmo_SetImGuiContext(void* ctx);
bool ImGuizmo_IsOver(void);
bool ImGuizmo_IsUsing(void);
bool ImGuizmo_IsUsingAny(void);
void ImGuizmo_Enable(bool enable);
void ImGuizmo_DecomposeMatrixToComponents(const float* matrix, float* translation, float* rotation, float* scale);
void ImGuizmo_RecomposeMatrixFromComponents(const float* translation, const float* rotation, const float* scale, float* matrix);
void ImGuizmo_SetRect(float x, float y, float width, float height);
void ImGuizmo_SetOrthographic(bool isOrthographic);
void ImGuizmo_DrawGrid(const float* view, const float* projection, const float* matrix, const float gridSize);
bool ImGuizmo_Manipulate(const float* view, const float* projection, ImGuizmo_Operation operation, ImGuizmo_Mode mode, float* matrix, float* deltaMatrix, const float* snap, const float* localBounds, const float* boundsSnap);
void ImGuizmo_ViewManipulate(float* view, float length, float pos_x, float pos_y, float size_x, float size_y, uint32_t backgroundColor);
void ImGuizmo_AllowAxisFlip(bool value);
void ImGuizmo_SetGizmoSizeClipSpace(float value);

#ifdef __cplusplus
}
#endif
