 ┌─────────────┐
 │ Glyph Quad  │
 └──────┬──────┘
        │ sample α from texture
        ▼
┌─────────────────────────────┐
│           PASS 1             │
│     (Opaque Core Only)       │
│----------------------------- │
│ if α < 0.99 → discard        │
│ depth test = ON              │
│ depth write = ON             │
│ blending = OFF               │
│ outColor = vec4(color, 1.0)  │
└─────────────────────────────┘
        │
        ▼
 Depth buffer now matches
 crisp glyph silhouette

        ▼
┌─────────────────────────────┐
│           PASS 2             │
│     (Smooth Edge Pixels)     │
│----------------------------- │
│ if α ≥ 0.99 or α ≤ 0.0 → discard
│ depth test = ON              │
│ depth write = OFF            │
│ blending = ON (srcα, 1-srcα) │
│ outColor = vec4(color, α)    │
└─────────────────────────────┘
        │
        ▼
 Final framebuffer:
 crisp glyph depth + smooth edges

