--!strict
--[[
	ACF server-side type definitions.

	Lives under ServerScriptService and never replicates to clients. Runtime value of
	this module is an empty table; it exists for its exported types.
]]

export type LogLevel = "Debug" | "Info" | "Warn" | "Error"

export type LogFields = { [string]: any }

export type LogEntry = {
	Time: number,
	WallTime: number,
	Level: LogLevel,
	Scope: string,
	Message: string,
	Fields: LogFields?,
	-- Number of identical (scope + message) entries dropped by rate limiting since the
	-- previous emitted entry with the same key.
	Suppressed: number?,
}

export type Clock = {
	-- Monotonic seconds. Used for all durations, windows and decay.
	Now: () -> number,
	-- Unix epoch seconds. Used only for audit timestamps.
	Wall: () -> number,
}

-- Minimal shapes ACF needs from Roblox objects. Real RBXScriptSignals, Players and
-- Player instances satisfy them; tests supply plain-table fakes.
export type ConnectionLike = any
export type SignalLike = any
export type PlayersLike = any
export type PlayerLike = any

-- One server-side observation of a character, produced by Environment.Physics:Sample.
-- Plain numbers so detectors run (and are tested) without Roblox datatypes.
export type MovementSample = {
	X: number,
	Y: number,
	Z: number,
	VX: number,
	VY: number,
	VZ: number,
	-- Magnitude of the root's angular velocity, rad/s.
	AngularSpeed: number,
	-- Server-side Humanoid.WalkSpeed (client changes never replicate, so this is authorized).
	WalkSpeed: number,
	-- Initial jump velocity implied by the server-side JumpPower / JumpHeight.
	JumpVelocity: number,
	Gravity: number,
	-- Distance from the feet to the ground below (0 when standing; math.huge when none
	-- within the probe range). Water counts as ground.
	GroundClearance: number,
	-- Humanoid state name, e.g. "Running", "Freefall", "Climbing", "Swimming", "Dead".
	State: string,
	Seated: boolean,
	Health: number,
	-- Round-trip network latency estimate in seconds (0 if unknown).
	Ping: number,
	-- Horizontal speed of the part the character stands on (moving platforms, trains,
	-- conveyors). Added to the allowed speed. Optional; 0 when absent.
	GroundSpeed: number?,
}

-- What the server knows about a part a client claims to have hit.
export type TargetInfo = {
	X: number,
	Y: number,
	Z: number,
	-- The character/NPC model the part belongs to (identity key), or nil for world parts.
	Model: any?,
	Humanoid: any?,
	Alive: boolean,
	-- The Player owning that character, if any.
	Player: any?,
	IsHead: boolean,
}

export type PhysicsService = {
	-- Describes a hit part (position, owning model, alive, head). nil if not a BasePart.
	Describe: ((self: any, part: any) -> TargetInfo?)?,
	-- Observes a character. Returns nil if it has no root part / humanoid yet.
	Sample: (self: any, character: any, player: any) -> MovementSample?,
	-- Casts a ray against collidable world geometry (characters excluded). Returns the
	-- distance to the first hit, or nil.
	Cast: (self: any, ox: number, oy: number, oz: number, dx: number, dy: number, dz: number, character: any) -> number?,
}

export type RemoteProvider = {
	-- Returns ACF's own remote with this name, creating it if needed.
	GetOrCreate: (self: any, name: string, className: string) -> any,
}

export type Environment = {
	Players: PlayersLike,
	-- Character observation and spatial queries (required by Movement/Physics).
	Physics: PhysicsService?,
	-- Creates ACF-owned remotes (required by Telemetry).
	Remotes: RemoteProvider?,
	-- Per-frame signal that drives the Scheduler. When nil, the host must call
	-- Framework:Step() itself (tests do this with a fake clock).
	Heartbeat: SignalLike?,
	Clock: Clock,
	GenerateId: () -> string,
	-- Receives every emitted log entry. Defaults to print/warn formatting.
	LogSink: ((LogEntry) -> ())?,
}

export type DetectionCategory =
	"Movement"
	| "Physics"
	| "Remote"
	| "Combat"
	| "Economy"
	| "Behavioral"
	| "Integrity"
	| "Custom"

-- What a detection module passes to context:Report().
export type DetectionInput = {
	-- Short machine-readable identifier of what was observed, e.g. "SpeedExceeded".
	Kind: string,
	-- Risk weight of this observation at full confidence, 0..100.
	Severity: number,
	-- Probability-like certainty that the observation indicates cheating, 0..1.
	Confidence: number,
	-- Optional structured context. Sanitised and size-bounded before storage.
	Details: { [string]: any }?,
}

-- Normalised, immutable detection event produced by the DetectionManager.
export type DetectionEvent = {
	Id: string,
	Detector: string,
	Category: DetectionCategory,
	Kind: string,
	UserId: number,
	SessionId: string,
	Severity: number,
	Confidence: number,
	Time: number,
	WallTime: number,
	Details: { [string]: any },
}

-- Aggregated evidence. Repeated identical detections inside the duplicate window are
-- merged into one record instead of creating new ones.
export type EvidenceRecord = {
	Id: string,
	UserId: number,
	SessionId: string,
	Detector: string,
	Category: DetectionCategory,
	Kind: string,
	Severity: number,
	Confidence: number,
	Count: number,
	FirstSeen: number,
	LastSeen: number,
	FirstWallTime: number,
	LastWallTime: number,
	FirstEventId: string,
	Details: { [string]: any },
}

export type ModuleState =
	"Registered"
	| "Initializing"
	| "Initialized"
	| "Starting"
	| "Running"
	| "Stopping"
	| "Stopped"
	| "Failed"
	| "Blocked"
	| "Disabled"
	| "Destroying"
	| "Destroyed"

export type FrameworkState = "Created" | "Initialized" | "Running" | "Stopped" | "Destroyed"

-- The handle a module receives in Initialize(context). See docs/MODULES.md.
export type ModuleContext = {
	Name: string,
	Config: { [string]: any },
	Logger: any,
	Clock: Clock,
	Cleanup: any,
	Events: any,
	Scheduler: any,
	Players: any,
	-- Read-only platform services; fields are nil when the host provides none.
	Platform: { Physics: PhysicsService?, Remotes: RemoteProvider? },
	Report: (self: any, target: any, input: DetectionInput) -> (boolean, string),
	GetConfig: (self: any, path: string) -> any,
	GetModule: (self: any, name: string) -> any,
}

export type ModuleDefinition = {
	Name: string,
	Version: string?,
	Category: DetectionCategory?,
	Dependencies: { string }?,
	Critical: boolean?,
	EnabledByDefault: boolean?,
	ConfigSchema: any?,
	Initialize: (self: any, context: ModuleContext) -> (),
	Start: (self: any) -> (),
	Stop: (self: any) -> (),
	Destroy: (self: any) -> (),
	[string]: any,
}

return {}
