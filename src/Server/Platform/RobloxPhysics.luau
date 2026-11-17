--!strict
--[[
	Roblox implementation of Environment.Physics: character sampling and spatial queries.

	Studio-only code path (the Lune suite uses a fake world); verify with the Studio run.

	Sample(character, player):
	  - root = HumanoidRootPart, humanoid = first Humanoid; nil if either is missing
	  - position / velocities from the root assembly
	  - GroundClearance: downward raycast (characters excluded, water counts as ground)
	    minus the standing height (HipHeight + half root height, + 2 for R6 legs)
	  - JumpVelocity from the server-side JumpPower / JumpHeight
	  - Ping from Player:GetNetworkPing() (seconds, round trip estimate)

	Cast(...): workspace:Raycast with RespectCanCollide, excluding every player
	character. The exclusion list is refreshed at most once per second.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Types = require(script.Parent.Parent.Types)

local GROUND_PROBE_DISTANCE = 64
local EXCLUDE_REFRESH_SECONDS = 1

local RobloxPhysics = {}

function RobloxPhysics.create(): Types.PhysicsService
	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	groundParams.IgnoreWater = false
	groundParams.RespectCanCollide = true

	local castParams = RaycastParams.new()
	castParams.FilterType = Enum.RaycastFilterType.Exclude
	castParams.IgnoreWater = true
	castParams.RespectCanCollide = true

	local characters: { Instance } = {}
	local refreshedAt = -math.huge

	local function refreshCharacters()
		local now = os.clock()
		if now - refreshedAt < EXCLUDE_REFRESH_SECONDS then
			return
		end
		refreshedAt = now
		table.clear(characters)
		for _, player in Players:GetPlayers() do
			local character = player.Character
			if character then
				table.insert(characters, character)
			end
		end
		groundParams.FilterDescendantsInstances = characters
		castParams.FilterDescendantsInstances = characters
	end

	local service = {}

	function service.Sample(_self: any, character: Model, player: Player?): Types.MovementSample?
		local root = character:FindFirstChild("HumanoidRootPart")
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if root == nil or humanoid == nil or not root:IsA("BasePart") then
			return nil
		end
		refreshCharacters()
		if not table.find(characters, character) then
			-- Newly spawned character not yet in the exclusion list.
			refreshedAt = -math.huge
			refreshCharacters()
		end

		local position = root.Position
		local velocity = root.AssemblyLinearVelocity
		local gravity = Workspace.Gravity
		local jumpVelocity = if humanoid.UseJumpPower
			then humanoid.JumpPower
			else math.sqrt(2 * gravity * math.max(humanoid.JumpHeight, 0))

		local legs = if humanoid.RigType == Enum.HumanoidRigType.R6 then 2 else 0
		local standingHeight = humanoid.HipHeight + root.Size.Y / 2 + legs
		local hit = Workspace:Raycast(position, Vector3.new(0, -GROUND_PROBE_DISTANCE, 0), groundParams)
		local clearance = if hit then math.max(0, (position.Y - hit.Position.Y) - standingHeight) else math.huge
		local groundSpeed = 0
		if hit and clearance <= 2 and hit.Instance:IsA("BasePart") then
			local groundVelocity = (hit.Instance :: BasePart).AssemblyLinearVelocity
			groundSpeed = math.sqrt(groundVelocity.X * groundVelocity.X + groundVelocity.Z * groundVelocity.Z)
		end

		local ping = 0
		if player then
			local ok, value = pcall(function()
				return player:GetNetworkPing()
			end)
			if ok and type(value) == "number" then
				ping = value
			end
		end

		return {
			X = position.X,
			Y = position.Y,
			Z = position.Z,
			VX = velocity.X,
			VY = velocity.Y,
			VZ = velocity.Z,
			AngularSpeed = root.AssemblyAngularVelocity.Magnitude,
			WalkSpeed = humanoid.WalkSpeed,
			JumpVelocity = jumpVelocity,
			Gravity = gravity,
			GroundClearance = clearance,
			State = humanoid:GetState().Name,
			Seated = humanoid.SeatPart ~= nil,
			Health = humanoid.Health,
			Ping = ping,
			GroundSpeed = groundSpeed,
		}
	end

	function service.Describe(_self: any, part: Instance): Types.TargetInfo?
		if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
			return nil
		end
		local position = (part :: BasePart).Position
		local model = part:FindFirstAncestorOfClass("Model")
		local humanoid = if model then model:FindFirstChildOfClass("Humanoid") else nil
		return {
			X = position.X,
			Y = position.Y,
			Z = position.Z,
			Model = if humanoid then model else nil,
			Humanoid = humanoid,
			Alive = humanoid ~= nil and humanoid.Health > 0,
			Player = if model then Players:GetPlayerFromCharacter(model) else nil,
			IsHead = part.Name == "Head",
		}
	end

	function service.Cast(_self: any, ox: number, oy: number, oz: number, dx: number, dy: number, dz: number, _character: any): number?
		refreshCharacters()
		local result = Workspace:Raycast(Vector3.new(ox, oy, oz), Vector3.new(dx, dy, dz), castParams)
		return if result then result.Distance else nil
	end

	return service :: any
end

return RobloxPhysics
