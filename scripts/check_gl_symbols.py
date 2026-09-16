#!/usr/bin/env python3
"""
check_gl_symbols.py — Regression guard for OpenGL symbols vs pinned version.

Verifies:
1. Pinned GL version in src/app/window.odin (GL_MAJOR, GL_MINOR).
2. All gl.* symbols called across src/ require a version <= pinned version.
3. If an uninitialized symbol (requiring > pinned version) is called, fails with file:line.
"""

import os
import re
import sys
from pathlib import Path

SRC_DIR = Path("src")
WINDOW_ODIN = SRC_DIR / "app" / "window.odin"

# Symbols requiring OpenGL 4.5 (from vendor:OpenGL load_4_5)
GL_4_5_SYMBOLS = {
    # Direct State Access (DSA)
    "ClipControl",
    "CreateTransformFeedbacks",
    "TransformFeedbackBufferBase",
    "TransformFeedbackBufferRange",
    "GetTransformFeedbackiv",
    "GetTransformFeedbacki_v",
    "GetTransformFeedbacki64_v",
    "CreateBuffers",
    "NamedBufferStorage",
    "NamedBufferData",
    "NamedBufferSubData",
    "CopyNamedBufferSubData",
    "ClearNamedBufferData",
    "ClearNamedBufferSubData",
    "MapNamedBuffer",
    "MapNamedBufferRange",
    "UnmapNamedBuffer",
    "FlushMappedNamedBufferRange",
    "GetNamedBufferParameteriv",
    "GetNamedBufferParameteri64v",
    "GetNamedBufferPointerv",
    "GetNamedBufferSubData",
    "CreateFramebuffers",
    "NamedFramebufferRenderbuffer",
    "NamedFramebufferParameteri",
    "NamedFramebufferTexture",
    "NamedFramebufferTextureLayer",
    "NamedFramebufferDrawBuffer",
    "NamedFramebufferDrawBuffers",
    "NamedFramebufferReadBuffer",
    "InvalidateNamedFramebufferData",
    "InvalidateNamedFramebufferSubData",
    "ClearNamedFramebufferiv",
    "ClearNamedFramebufferuiv",
    "ClearNamedFramebufferfv",
    "ClearNamedFramebufferfi",
    "BlitNamedFramebuffer",
    "CheckNamedFramebufferStatus",
    "GetNamedFramebufferParameteriv",
    "GetNamedFramebufferAttachmentParameteriv",
    "CreateRenderbuffers",
    "NamedRenderbufferStorage",
    "NamedRenderbufferStorageMultisample",
    "GetNamedRenderbufferParameteriv",
    "CreateTextures",
    "TextureBuffer",
    "TextureBufferRange",
    "TextureStorage1D",
    "TextureStorage2D",
    "TextureStorage3D",
    "TextureStorage2DMultisample",
    "TextureStorage3DMultisample",
    "TextureSubImage1D",
    "TextureSubImage2D",
    "TextureSubImage3D",
    "CompressedTextureSubImage1D",
    "CompressedTextureSubImage2D",
    "CompressedTextureSubImage3D",
    "CopyTextureSubImage1D",
    "CopyTextureSubImage2D",
    "CopyTextureSubImage3D",
    "TextureParameterf",
    "TextureParameterfv",
    "TextureParameteri",
    "TextureParameterIiv",
    "TextureParameterIuiv",
    "TextureParameteriv",
    "GenerateTextureMipmap",
    "BindTextureUnit",
    "GetTextureImage",
    "GetCompressedTextureImage",
    "GetTextureLevelParameterfv",
    "GetTextureLevelParameteriv",
    "GetTextureParameterfv",
    "GetTextureParameterIiv",
    "GetTextureParameterIuiv",
    "GetTextureParameteriv",
    "GetTextureSubImage",
    "GetCompressedTextureSubImage",
    "CreateVertexArrays",
    "DisableVertexArrayAttrib",
    "EnableVertexArrayAttrib",
    "VertexArrayElementBuffer",
    "VertexArrayVertexBuffer",
    "VertexArrayVertexBuffers",
    "VertexArrayAttribBinding",
    "VertexArrayAttribFormat",
    "VertexArrayAttribIFormat",
    "VertexArrayAttribLFormat",
    "VertexArrayBindingDivisor",
    "GetVertexArrayiv",
    "GetVertexArrayIndexediv",
    "GetVertexArrayIndexed64iv",
    "CreateSamplers",
    "CreateProgramPipelines",
    "CreateQueries",
    "GetQueryBufferObjecti64v",
    "GetQueryBufferObjectiv",
    "GetQueryBufferObjectui64v",
    "GetQueryBufferObjectuiv",
    "MemoryBarrierByRegion",
    "TextureBarrier",
    "GetGraphicsResetStatus",
    "GetnCompressedTexImage",
    "GetnTexImage",
    "GetnUniformdv",
    "GetnUniformfv",
    "GetnUniformiv",
    "GetnUniformuiv",
    "ReadnPixels",
    "GetnMapdv",
    "GetnMapfv",
    "GetnMapiv",
    "GetnPixelMapfv",
    "GetnPixelMapuiv",
    "GetnPixelMapusv",
    "GetnPolygonStipple",
    "GetnColorTable",
    "GetnConvolutionFilter",
    "GetnSeparableFilter",
    "GetnHistogram",
    "GetnMinmax",
    "GetUnsignedBytevEXT",
    "TexPageCommitmentARB",
}

# Symbols requiring OpenGL 4.6 (from vendor:OpenGL load_4_6)
GL_4_6_SYMBOLS = {
    "SpecializeShader",
    "MultiDrawArraysIndirectCount",
    "MultiDrawElementsIndirectCount",
    "PolygonOffsetClamp",
}

SYMBOL_VERSIONS = {}
for sym in GL_4_5_SYMBOLS:
    SYMBOL_VERSIONS[sym] = (4, 5)
for sym in GL_4_6_SYMBOLS:
    SYMBOL_VERSIONS[sym] = (4, 6)


def get_pinned_gl_version() -> tuple[int, int]:
    if not WINDOW_ODIN.is_file():
        print(f"ERROR: {WINDOW_ODIN} not found!", file=sys.stderr)
        sys.exit(1)

    content = WINDOW_ODIN.read_text(encoding="utf-8")
    major_match = re.search(r"\bGL_MAJOR\s*::\s*(\d+)", content)
    minor_match = re.search(r"\bGL_MINOR\s*::\s*(\d+)", content)

    if not major_match or not minor_match:
        print(f"ERROR: Could not parse GL_MAJOR / GL_MINOR from {WINDOW_ODIN}", file=sys.stderr)
        sys.exit(1)

    return int(major_match.group(1)), int(minor_match.group(1))


def main() -> int:
    pinned_version = get_pinned_gl_version()
    pinned_str = f"{pinned_version[0]}.{pinned_version[1]}"
    print(f"=== CHECK OPENGL SYMBOLS AUDIT (Pinned GL Version: {pinned_str}) ===")

    gl_call_re = re.compile(r"\bgl\.([A-Za-z0-9_]+)\b")

    violations = []
    scanned_files = 0
    symbols_checked = 0

    for root, _, files in os.walk(SRC_DIR):
        for fname in sorted(files):
            if not fname.endswith(".odin"):
                continue
            fpath = Path(root) / fname
            scanned_files += 1

            try:
                lines = fpath.read_text(encoding="utf-8").splitlines()
            except UnicodeDecodeError:
                continue

            for line_idx, line in enumerate(lines, start=1):
                # Ignore pure comment lines
                stripped = line.strip()
                if stripped.startswith("//"):
                    continue

                for match in gl_call_re.finditer(line):
                    sym = match.group(1)
                    if sym in SYMBOL_VERSIONS:
                        symbols_checked += 1
                        required_ver = SYMBOL_VERSIONS[sym]
                        if required_ver > pinned_version:
                            req_str = f"{required_ver[0]}.{required_ver[1]}"
                            violations.append((fpath, line_idx, sym, req_str))

    print(f"Scanned {scanned_files} files across {SRC_DIR}/.")
    print(f"Total version-gated GL symbols inspected: {symbols_checked}")

    if violations:
        print(
            f"\n❌ FAIL: Found {len(violations)} GL symbol call(s) exceeding pinned GL {pinned_str}:",
            file=sys.stderr,
        )
        for fpath, line_no, sym, req_str in violations:
            print(f"  {fpath}:{line_no}: gl.{sym} requires OpenGL {req_str} (pinned: {pinned_str})", file=sys.stderr)
        return 1

    print(f"✅ PASS: All GL symbols in {SRC_DIR}/ are <= pinned OpenGL {pinned_str}.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
