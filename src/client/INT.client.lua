local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)

local function FuncReqControllers(Dir)
	Knit.AddControllersDeep(Dir)
end

FuncReqControllers(script.Parent.Controllers)

Knit.Start():catch(warn)
