include("shared.lua")

-- Keeping the clientside draw nice and boring; the prop already says everything.
function ENT:Draw()
    self:DrawModel()
end
