EPS = EPS or {}
EPS.Config = {
  -- Full ship-wide EPS capacity. Sized just above the combined subsystem peaks so we stay flexible when things spike.
  MaxBudget = 860,

  -- Sliders shown in the UI. These represent the full EPS subsystem library; consoles will
  -- pick a subset depending on where they are on the ship. Defaults sit at roughly eighty percent of the spike cap.
  Subsystems = {
    { id = "life_support",              label = "Life Support",                   min = 42, max =  60, overdrive =  72, default = 48 },
    { id = "replicators.general",       label = "Replicators",                    min =  4, max =  28, overdrive =  34, default = 22 },
    { id = "replicators.industrial",    label = "Industrial Replicators",         min =  2, max =  26, overdrive =  31, default = 21 },
    { id = "forcefields",               label = "Forcefields",                    min =  8, max =  32, overdrive =  38, default = 26 },
    { id = "helm_control",              label = "Helm Control",                   min =  8, max =  25, overdrive =  30, default = 20 },
    { id = "communications",            label = "Communications",                 min =  6, max =  22, overdrive =  26, default = 18 },
    { id = "shields",                   label = "Deflector Shields",              min = 24, max =  55, overdrive =  66, default = 44 },
    { id = "weapons",                   label = "Tactical Weapon Systems",        min = 18, max =  50, overdrive =  60, default = 40 },
    { id = "sensors",                   label = "Long-Range Sensors",             min = 12, max =  36, overdrive =  43, default = 29 },
    { id = "impulse_engines",           label = "Impulse Engines",                min = 20, max =  52, overdrive =  62, default = 42 },
    { id = "hydroponics",               label = "Hydroponics Systems",            min =  2, max =  18, overdrive =  22, default = 14 },
    { id = "beer_taps",                 label = "Beverage Dispensers",            min =  0, max =  12, overdrive =  14, default = 10 },
    { id = "lighting",                  label = "Ambient Lighting",               min =  6, max =  20, overdrive =  24, default = 16 },
    { id = "pattern_buffers",           label = "Pattern Buffers",                min =  8, max =  30, overdrive =  36, default = 24 },
    { id = "heisenberg_compensators",   label = "Heisenberg Compensators",        min =  8, max =  26, overdrive =  31, default = 21 },
    { id = "transporter_pad",           label = "Transporter Pad Grid",           min =  8, max =  24, overdrive =  29, default = 19 },
    { id = "holoemitters",              label = "Holoemitters",                   min =  6, max =  28, overdrive =  34, default = 22 },
    { id = "holodeck_safety",           label = "Holodeck Safety Interlocks",     min =  8, max =  20, overdrive =  24, default = 16 },
    { id = "cargo_transporters",        label = "Cargo Transporters",             min =  8, max =  30, overdrive =  36, default = 24 },
    { id = "matter_antimatter_flow",    label = "Matter/Antimatter Flow Reg.",    min = 40, max =  64, overdrive =  77, default = 51 },
    { id = "slipstream_drive",          label = "Slipstream Drive",               min =  8, max =  82, overdrive =  98, default = 66 },
    { id = "auxiliary_power",           label = "Auxiliary Power Matrix",         min = 20, max = 140, overdrive = 180, default = 112 },
    { id = "sickbay_lab",               label = "Sickbay Lab Systems",            min = 10, max =  26, overdrive =  31, default = 21 },
    { id = "medical_scanner",           label = "Medical Diagnostic Scanners",    min =  8, max =  22, overdrive =  26, default = 18 },
    { id = "biofilters",                label = "Biofilters & Sterilization",     min = 10, max =  24, overdrive =  29, default = 19 }
  },

  -- Who's allowed to tweak power.
  -- Add ULX groups or team names here. Leave empty to let anyone adjust.
  AllowedGroups = { },

  -- Random “uh-oh” moments to keep Engineering and Ops busy.
  Spikes = {
    Enabled = true,

    -- How often spikes show up and how long they last.
    -- Timings still give Engineering something to do without turning it into constant whack-a-mole.
    IntervalMin = 150,  -- earliest a spike can start after the last one (seconds)
    IntervalMax = 360,  -- latest a spike can start (seconds)
    DurationMin =  75,  -- shortest spike (seconds)
    DurationMax = 150,  -- longest spike (seconds)

    -- Which systems are most likely to get hit.
    -- Higher number = more likely.
    Weights = {
      life_support = 4,
      ["replicators.general"] = 2,
      ["replicators.industrial"] = 2,
      forcefields = 3,
      helm_control = 2,
      communications = 2,
      shields = 4,
      weapons = 4,
      sensors = 3,
      impulse_engines = 3,
      hydroponics = 1,
      beer_taps = 1,
      lighting = 1,
      pattern_buffers = 2,
      heisenberg_compensators = 2,
      transporter_pad = 2,
      holoemitters = 1,
      holodeck_safety = 1,
      cargo_transporters = 2,
      matter_antimatter_flow = 4,
      slipstream_drive = 1,
      auxiliary_power = 3,
      sickbay_lab = 2,
      medical_scanner = 2,
      biofilters = 3,
    },

    -- Extra demand added during a spike.
    -- If a system doesn't have enough headroom, it'll warn in orange/red.
    ExtraDemandMin = 4,
    ExtraDemandMax = 12,

    -- Optional alert broadcast when a spike begins. Message placeholders: subsystem, deck, section name.
    AlertCommand = "/git",
    -- Manual override so command staff can kick off a panel-linked spike on demand.
    ForceCommand = "/pwrspike",
    AlertMessage = "Power fluctuations detected in %s. Deck %s, %s.",
    AlertRecoveryMessage = "Power allocation stabilized for %s. Deck %s, %s.",
  },

  DynamicLayouts = {
    default = { "replicators.general", "forcefields", "auxiliary_power" },
    alwaysInclude = { "life_support", "auxiliary_power" },

    deckOverrides = {
      [3] = { "replicators.general" },
    },

    sectionNames = {
      ["Section 1 Bridge"] = { "helm_control", "communications", "shields", "weapons", "sensors" },
      ["Section 2 Ready Room"] = { "replicators.general" },
      ["Section 13 Mess Hall"] = { "replicators.general" },
      ["Section 5 Assorted Room"] = { "hydroponics" },
      ["Section 4 VIP Quarters 2"] = { "beer_taps", "lighting", "replicators.general" },
      ["Section 4 Security"] = { "replicators.general", "forcefields" },
      ["Section 5 Brig 1"] = { "replicators.general", "forcefields" },
      ["Section 6 Brig 2"] = { "replicators.general", "forcefields" },
      ["Section 7 Brig 3"] = { "replicators.general", "forcefields" },
      ["Section 8 Brig 4"] = { "replicators.general", "forcefields" },
      ["Section 3 Transporterroom 1"] = { "pattern_buffers", "heisenberg_compensators", "transporter_pad", "forcefields", "replicators.general" },
      ["Section 15B Sickbay Lab"] = { "sickbay_lab", "medical_scanner", "biofilters", "forcefields", "replicators.general" },
      ["Section 3 Holodeck 1"] = { "holoemitters", "holodeck_safety", "replicators.general" },
      ["Section 4 Holodeck 2"] = { "holoemitters", "holodeck_safety", "replicators.general" },
      ["Section 7 Cargobay 7"] = { "replicators.industrial", "cargo_transporters", "forcefields" },
      ["Section 4 Engineering"] = { "matter_antimatter_flow", "impulse_engines", "slipstream_drive", "auxiliary_power", "replicators.general", "forcefields" }
    }
  },

  -- Open the UI via chat or console.
  Commands = {
    Chat = "/eps",
    ConCommand = "eps_open",
  }
}
