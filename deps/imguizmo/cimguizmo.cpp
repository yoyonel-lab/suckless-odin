#include "cimguizmo.h"
#include "../odin-imgui/imgui/imgui.h"
#include "ImGuizmo.h"

extern "C" {

void ImGuizmo_SetDrawlist(void* drawlist) {
    ImGuizmo::SetDrawlist((ImDrawList*)drawlist);
}

void ImGuizmo_BeginFrame(void) {
    ImGuizmo::BeginFrame();
}

void ImGuizmo_SetImGuiContext(void* ctx) {
    ImGuizmo::SetImGuiContext((ImGuiContext*)ctx);
}

bool ImGuizmo_IsOver(void) {
    return ImGuizmo::IsOver();
}

bool ImGuizmo_IsUsing(void) {
    return ImGuizmo::IsUsing();
}

bool ImGuizmo_IsUsingAny(void) {
    return ImGuizmo::IsUsingAny();
}

void ImGuizmo_Enable(bool enable) {
    ImGuizmo::Enable(enable);
}

void ImGuizmo_DecomposeMatrixToComponents(const float* matrix, float* translation, float* rotation, float* scale) {
    ImGuizmo::DecomposeMatrixToComponents(matrix, translation, rotation, scale);
}

void ImGuizmo_RecomposeMatrixFromComponents(const float* translation, const float* rotation, const float* scale, float* matrix) {
    ImGuizmo::RecomposeMatrixFromComponents(translation, rotation, scale, matrix);
}

void ImGuizmo_SetRect(float x, float y, float width, float height) {
    ImGuizmo::SetRect(x, y, width, height);
}

void ImGuizmo_SetOrthographic(bool isOrthographic) {
    ImGuizmo::SetOrthographic(isOrthographic);
}

void ImGuizmo_DrawGrid(const float* view, const float* projection, const float* matrix, const float gridSize) {
    ImGuizmo::DrawGrid(view, projection, matrix, gridSize);
}

bool ImGuizmo_Manipulate(const float* view, const float* projection, ImGuizmo_Operation operation, ImGuizmo_Mode mode, float* matrix, float* deltaMatrix, const float* snap, const float* localBounds, const float* boundsSnap) {
    return ImGuizmo::Manipulate(
        view,
        projection,
        (ImGuizmo::OPERATION)operation,
        (ImGuizmo::MODE)mode,
        matrix,
        deltaMatrix,
        snap,
        localBounds,
        boundsSnap
    );
}

void ImGuizmo_ViewManipulate(float* view, float length, float pos_x, float pos_y, float size_x, float size_y, uint32_t backgroundColor) {
    ImVec2 pos(pos_x, pos_y);
    ImVec2 size(size_x, size_y);
    ImGuizmo::ViewManipulate(view, length, pos, size, backgroundColor);
}

void ImGuizmo_AllowAxisFlip(bool value) {
    ImGuizmo::AllowAxisFlip(value);
}

void ImGuizmo_SetGizmoSizeClipSpace(float value) {
    ImGuizmo::SetGizmoSizeClipSpace(value);
}

}
