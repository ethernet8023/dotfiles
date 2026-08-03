# Helpers for writing Hyprland's Lua config through the home-manager module.
#
# Used with wayland.windowManager.hyprland.configType = "lua".
# The home-manager renderer turns settings into hl.<name>(...) calls.
# These helpers produce the Nix structures it expects (_args, _var, LuaInline).
{ lib }:
let
  inherit (lib)
    concatMapStringsSep
    concatStringsSep
    foldl'
    mergeAttrs
    optionalAttrs
    range
    ;

  inherit (lib.generators)
    mkLuaInline
    toLua
    ;

  # Default Lua serializer.
  lua = toLua { };
in
rec {
  # -- home-manager structural shorthands --
  call = args: { _args = args; };
  var = name: value: {
    _var = value;
    inherit name;
  };

  # -- key strings --
  key = mods: k: if mods == "" then k else "${mods} + ${k}";
  noMod = key "";

  # -- flags (combine with flags [ locked repeating ... ]) --
  flags = foldl' mergeAttrs { };
  locked = {
    locked = true;
  };
  repeating = {
    repeating = true;
  };
  release = {
    release = true;
  };
  longPress = {
    long_press = true;
  };
  mouse = {
    mouse = true;
  };
  click = {
    click = true;
  };
  dragFlag = {
    drag = true;
  };
  submapUniversal = {
    submap_universal = true;
  };
  ignoreMods = {
    ignore_mods = true;
  };
  nonConsuming = {
    non_consuming = true;
  };
  device = { inclusive, list }: { device = { inherit inclusive list; }; };
  description = text: { description = text; };

  # -- raw Lua snippets --
  raw = mkLuaInline;

  # -- startup / events --
  onEvent = event: commands: {
    _args = [
      event
      (mkLuaInline ''
        function()
          ${concatMapStringsSep "\n  " (c: "hl.exec_cmd(${lua c})") commands}
        end
      '')
    ];
  };

  multi =
    actions:
    mkLuaInline ''
      function()
        ${concatMapStringsSep "\n  " (a: "hl.dispatch(${lua a})") actions}
      end
    '';

  # -- dispatchers (produce LuaInline expressions for hl.bind) --
  exec = cmd: mkLuaInline "hl.dsp.exec_cmd(${lua cmd})";
  execWithRules = cmd: rules: mkLuaInline "hl.dsp.exec_cmd(${lua cmd}, ${lua rules})";
  execRaw = cmd: mkLuaInline "hl.dsp.exec_raw(${lua cmd})";

  focus = {
    dir = d: mkLuaInline "hl.dsp.focus({ direction = ${lua d} })";
    workspace = ws: mkLuaInline "hl.dsp.focus({ workspace = ${lua ws} })";
    workspaceOnCurrent =
      ws: mkLuaInline "hl.dsp.focus({ workspace = ${lua ws}, on_current_monitor = true })";
    window = w: mkLuaInline "hl.dsp.focus({ window = ${lua w} })";
    monitor = m: mkLuaInline "hl.dsp.focus({ monitor = ${lua m} })";
    last = mkLuaInline "hl.dsp.focus({ last = true })";
    urgentOrLast = mkLuaInline "hl.dsp.focus({ urgent_or_last = true })";
  };

  window = {
    close = mkLuaInline "hl.dsp.window.close()";
    kill = mkLuaInline "hl.dsp.window.kill()";
    float = action: mkLuaInline "hl.dsp.window.float(${lua { action = action; }})";
    floatToggle = mkLuaInline "hl.dsp.window.float({})";
    fullscreen = mode: mkLuaInline "hl.dsp.window.fullscreen(${lua { mode = mode; }})";
    fullscreenToggle = mkLuaInline "hl.dsp.window.fullscreen({})";
    pseudo = action: mkLuaInline "hl.dsp.window.pseudo(${lua { action = action; }})";
    pseudoToggle = mkLuaInline "hl.dsp.window.pseudo({})";
    move = args: mkLuaInline "hl.dsp.window.move(${lua args})";
    moveDir = d: mkLuaInline "hl.dsp.window.move({ direction = ${lua d} })";
    moveToWorkspace = ws: mkLuaInline "hl.dsp.window.move({ workspace = ${lua ws} })";
    moveToMonitor = m: mkLuaInline "hl.dsp.window.move({ monitor = ${lua m} })";
    center = mkLuaInline "hl.dsp.window.center({})";
    pin = action: mkLuaInline "hl.dsp.window.pin(${lua { action = action; }})";
    pinToggle = mkLuaInline "hl.dsp.window.pin({})";
    cycleNext = mkLuaInline "hl.dsp.window.cycle_next({})";
    cyclePrev = mkLuaInline "hl.dsp.window.cycle_next({ prev = true })";
    bringToTop = mkLuaInline "hl.dsp.window.bring_to_top()";
    alterZorder = mode: mkLuaInline "hl.dsp.window.alter_zorder({ mode = ${lua mode} })";
    drag = mkLuaInline "hl.dsp.window.drag()";
    resize = mkLuaInline "hl.dsp.window.resize()";
    resizeKeepAspect = mkLuaInline "hl.dsp.window.resize({ keep_aspect_ratio = true })";
    setProp = args: mkLuaInline "hl.dsp.window.set_prop(${lua args})";
  };

  workspace = {
    next = mkLuaInline "hl.dsp.focus({ workspace = \"e+1\" })";
    prev = mkLuaInline "hl.dsp.focus({ workspace = \"e-1\" })";
    previous = mkLuaInline "hl.dsp.focus({ workspace = \"previous\" })";
    rename =
      { workspace, name }:
      mkLuaInline "hl.dsp.workspace.rename({ workspace = ${lua workspace}, name = ${lua name} })";
    moveToMonitor =
      { workspace, monitor }:
      mkLuaInline "hl.dsp.workspace.move({ workspace = ${lua workspace}, monitor = ${lua monitor} })";
    toggleSpecial = name: mkLuaInline "hl.dsp.workspace.toggle_special(${lua name})";
  };

  layout = msg: mkLuaInline "hl.dsp.layout(${lua msg})";
  submap = name: mkLuaInline "hl.dsp.submap(${lua name})";

  pass =
    {
      window ? null,
      mods ? null,
      key ? null,
      ...
    }@args:
    if mods != null then
      mkLuaInline "hl.dsp.send_shortcut(${lua args})"
    else
      mkLuaInline "hl.dsp.pass(${lua args})";

  global = id: mkLuaInline "hl.dsp.global(${lua id})";

  # -- binds (produce _args tables that become hl.bind(...) calls) --
  bind = keycomb: dispatcher: {
    _args = [
      keycomb
      dispatcher
    ];
  };
  bindf = keycomb: dispatcher: fl: {
    _args = [
      keycomb
      dispatcher
      fl
    ];
  };

  # -- monitor / window-rule helpers --
  monitor = args: args;
  windowRule = attrs: attrs;
  floatRule = match: {
    inherit match;
    float = true;
  };
  tileRule = match: {
    inherit match;
    tile = true;
  };
  workspaceRule = match: ws: {
    inherit match;
    workspace = ws;
  };

  # bulk workspace number binds (mirrors the old hyprlang workspace loop)
  workspaceBinds =
    {
      mod,
      shiftMod ? "${mod} + SHIFT",
      count ? 10,
    }:
    builtins.concatLists (
      builtins.genList (
        x:
        let
          n = x + 1;
          # map 10 -> "0" to match a typical top-row key
          c = n / 10;
          keyName = toString (n - (c * 10));
        in
        [
          (bind (key mod keyName) (focus.workspace n))
          (bind (key shiftMod keyName) (window.moveToWorkspace n))
        ]
      ) count
    );
}
