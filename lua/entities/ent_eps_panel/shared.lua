ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "EPS Panel"
ENT.Category  = "Starfleet — Engineering"
ENT.Author    = "noofficial"

ENT.Spawnable      = true
ENT.AdminSpawnable = true
ENT.RenderGroup    = RENDERGROUP_OPAQUE
ENT.Editable       = true
ENT.UseType        = SIMPLE_USE
ENT.SparkOffset    = Vector(6, 0, 32)

if CLIENT then
    language.Add("ent_eps_panel", "EPS Panel") -- makes the spawn icon label nice
end
