package settings

// Global application constants, configuration, and default values.
// ISO port of app_settings.h from suckless-ogl.

// --- Renderer Configuration ---

DEFAULT_SAMPLES        :: 1     // MSAA sample count (1 = no MSAA)
DEFAULT_STENCIL_MASK   :: 0xFF  // All bits enabled

USE_TRANSPARENT_BILLBOARDS :: true  // Enable transparent billboard rendering

// --- Geometry Generation ---

MIN_SUBDIV             :: 0     // Minimum icosphere subdivision level
MAX_SUBDIV             :: 6     // Maximum subdivision level (~40k vertices at 6)
CUBEMAP_SIZE           :: 1024  // Legacy cubemap size
INITIAL_SUBDIVISIONS   :: 3     // Starting subdivision level

// --- Camera Configuration ---

DEFAULT_CAMERA_DISTANCE :: 20.0   // Initial orbit radius
DEFAULT_CAMERA_YAW      :: -90.0  // Initial horizontal angle (looking -Z)
DEFAULT_CAMERA_PITCH    :: 0.0    // Initial vertical angle (Horizon)
DEFAULT_ENV_LOD         :: 0.0    // Initial skybox blur level (0=Sharp)

// Projection matrix
NEAR_PLANE              :: 0.1    // Z-Near clip
FAR_PLANE               :: 1000.0 // Z-Far clip
FOV_ANGLE               :: 60.0   // Vertical FOV in degrees

// Gameplay constraints
MIN_CAMERA_DISTANCE     :: 1.5    // Closest zoom
MAX_CAMERA_DISTANCE     :: 50.0   // Furthest zoom

// --- Window Defaults ---

WINDOW_WIDTH            :: 1280
WINDOW_HEIGHT           :: 720

// --- Material Defaults ---

DEFAULT_METALLIC        :: 0.0
DEFAULT_ROUGHNESS       :: 0.5
DEFAULT_AO              :: 1.0
DEFAULT_EXPOSURE        :: 1.0

// --- N-Body Simulation ---

NUM_SPHERES             :: 50
G_CONSTANT              :: 0.5   // Gravitational constant
REPULSION_STRENGTH      :: 2.0
MIN_DISTANCE            :: 1.0

// --- Instancing Grid Layout ---

DEFAULT_COLS            :: 10
DEFAULT_SPACING         :: 2.5
HALF_OFFSET_MULTIPLIER  :: 0.5

// --- SIMD Alignment ---

SIMD_ALIGNMENT          :: 64    // 64-byte cache-line alignment
