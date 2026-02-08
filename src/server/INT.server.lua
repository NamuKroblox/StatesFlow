local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)

local function FuncReqServices(dir)
	for _, v in dir:GetDescendants() do
		if v:IsA("ModuleScript") and v.Name:match("Service$") then
			Knit.CreateService(require(v))
		end
	end
end

FuncReqServices(script.Parent.Services)

Knit.Start({
	ServicePromises = false,
}):catch(warn)
