--!strict
--[[
	Core event-bus topics. Topics in the "ACF." namespace are published only by the
	framework itself; modules may subscribe to them but cannot publish them.

	Payloads:
	  FrameworkStateChanged  { From: FrameworkState, To: FrameworkState }
	  ModuleStateChanged     { Name: string, From: ModuleState, To: ModuleState, Error: string? }
	  PlayerSessionStarted   { Session: Session }
	  PlayerSessionEnded     { Session: Session }
	  CharacterSpawned       { Session: Session, Character: Model, Generation: number }
	  CharacterRemoving      { Session: Session, Character: Model, Generation: number }
	  DetectionReported      { Event: DetectionEvent, Record: EvidenceRecord, IsNewRecord: boolean }
	  RiskChanged            { UserId: number, Session: Session?, Risk: number, Previous: number,
	                           Band: string, PreviousBand: string, Confidence: number,
	                           Explanation: string } (published when the band changes)
	  EnforcementAudit       AuditLog entry (every enforcement decision and staff action)
	  EnforcementCase        Case snapshot when a case is opened, updated or decided
]]

local Topics = table.freeze({
	FrameworkStateChanged = "ACF.FrameworkStateChanged",
	ModuleStateChanged = "ACF.ModuleStateChanged",
	PlayerSessionStarted = "ACF.PlayerSessionStarted",
	PlayerSessionEnded = "ACF.PlayerSessionEnded",
	CharacterSpawned = "ACF.CharacterSpawned",
	CharacterRemoving = "ACF.CharacterRemoving",
	DetectionReported = "ACF.DetectionReported",
	RiskChanged = "ACF.RiskChanged",
	EnforcementAudit = "ACF.EnforcementAudit",
	EnforcementCase = "ACF.EnforcementCase",
})

return Topics
