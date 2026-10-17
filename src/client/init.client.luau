local FirstPersonCamera = require(script.FirstPersonCamera)
local Hud = require(script.Hud)
local SwordController = require(script.SwordController)

FirstPersonCamera.start()
Hud.start(SwordController)
SwordController.start(FirstPersonCamera)
