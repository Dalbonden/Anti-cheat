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

export type Environment = {
	Players: PlayersLike,
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
