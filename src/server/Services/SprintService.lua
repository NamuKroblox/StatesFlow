local SprintService = {
	Name = "SprintService",
	Client = {},
}

function SprintService.Client:UpdateSpeed(player, isSprinting)
	self.Server:UpdateSpeed(player, isSprinting)
end

function SprintService:UpdateSpeed(player, isSprinting)
	-- Update the player's speed based on the isSprinting flag
	if isSprinting then
		player.Character.Humanoid.WalkSpeed = 32
	else
		player.Character.Humanoid.WalkSpeed = 16
	end
end

return SprintService
