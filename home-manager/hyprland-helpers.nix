# Helpers for writing Hyprland's Lua config through the home-manager module.
#
# Used with wayland.windowManager.hyprland.configType = "lua".
# The home-manager renderer turns settings into hl.<name>(...) calls.
# These helpers produce the Nix structures it expects (_args, _var, LuaInline).
{ lib }:
let
  inherit (lib)
    concatMapStringsSep
    foldl'
    mergeAttrs
    ;

  inherit (lib.generators)
    mkLuaInline
    toLua
    ;

  # Default Lua serializer.
  lua = toLua { };

  flags =
    let
      camelToSnake =
        str:
        let
          chars = lib.strings.stringToCharacters str;
          process =
            acc: c: if builtins.match "[A-Z]" c != null then acc + "_" + lib.strings.toLower c else acc + c;
        in
        lib.foldl process "" chars;

      mkFlags =
        flagList:
        builtins.listToAttrs (
          map (flag: {
            name = flag;
            value = {
              "${camelToSnake flag}" = true;
            };
          }) flagList
        );
    in
    mkFlags [
      "locked"
      "repeating"
      "release"
      "longPress"
      "mouse"
      "click"
      "drag"
      "submapUniversal"
      "ignoreMods"
      "nonConsuming"
    ];

in
flags
// rec {
  # -- home-manager structural shorthands --
  call = args: { _args = args; };
  var = name: value: {
    _var = value;
    inherit name;
  };

  # -- flags (combine with flags [ locked repeating ... ]) --
  flags = foldl' mergeAttrs { };
  device = { inclusive, list }: { device = { inherit inclusive list; }; };
  description = text: { description = text; };

  # -- raw Lua snippets: escape hatch, left completely untouched --
  raw = lib.id;

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

  # -- dsp generators: hl.dsp.<path>(<arg>) / hl.dsp.<path>() --
  # Every dispatcher below is one of these two shapes. Results are plain
  # strings, not yet LuaInline -- see `wrap`.
  dsp = path: arg: "hl.dsp.${path}(${lua arg})";
  dsp0 = path: "hl.dsp.${path}()";

  exec = dsp "exec_cmd";
  execWithRules = cmd: rules: "hl.dsp.exec_cmd(${lua cmd}, ${lua rules})"; # two args, doesn't fit dsp
  execRaw = dsp "exec_raw";

  focus = {
    dir = dir: dsp "focus" { direction = dir; };
    workspace = ws: dsp "focus" { workspace = ws; };
    workspaceOnCurrent =
      ws:
      dsp "focus" {
        workspace = ws;
        on_current_monitor = true;
      };
    window = w: dsp "focus" { window = w; };
    monitor = m: dsp "focus" { monitor = m; };
    last = dsp "focus" { last = true; };
    urgentOrLast = dsp "focus" { urgent_or_last = true; };
  };

  window = {
    close = dsp0 "window.close";
    kill = dsp0 "window.kill";
    float = action: dsp "window.float" { inherit action; };
    floatToggle = dsp "window.float" { };
    fullscreen = mode: dsp "window.fullscreen" { inherit mode; };
    fullscreenToggle = dsp "window.fullscreen" { };
    pseudo = action: dsp "window.pseudo" { inherit action; };
    pseudoToggle = dsp "window.pseudo" { };
    move = dsp "window.move";
    moveDir = dir: dsp "window.move" { direction = dir; };
    moveToWorkspace = ws: dsp "window.move" { workspace = ws; };
    moveToMonitor = m: dsp "window.move" { monitor = m; };
    center = dsp "window.center" { };
    pin = action: dsp "window.pin" { inherit action; };
    pinToggle = dsp "window.pin" { };
    cycleNext = dsp "window.cycle_next" { };
    cyclePrev = dsp "window.cycle_next" { prev = true; };
    bringToTop = dsp0 "window.bring_to_top";
    alterZorder = mode: dsp "window.alter_zorder" { inherit mode; };
    drag = dsp0 "window.drag";
    resize = dsp0 "window.resize";
    resizeKeepAspect = dsp "window.resize" { keep_aspect_ratio = true; };
    setProp = dsp "window.set_prop";
  };

  workspace = {
    next = dsp "focus" { workspace = "e+1"; };
    prev = dsp "focus" { workspace = "e-1"; };
    previous = dsp "focus" { workspace = "previous"; };
    rename = { workspace, name }: dsp "workspace.rename" { inherit workspace name; };
    moveToMonitor = { workspace, monitor }: dsp "workspace.move" { inherit workspace monitor; };
    toggleSpecial = dsp "workspace.toggle_special";
  };

  layout = dsp "layout";
  submap = dsp "submap";
  global = dsp "global";

  pass =
    {
      window ? null,
      mods ? null,
      key ? null,
      ...
    }@args:
    if mods != null then dsp "send_shortcut" args else dsp "pass" args;

  # -- wrap: the single point where a dispatcher expression (or a list of
  # them, when one bind should fire several dispatchers) becomes an actual
  # LuaInline value. Everything above stays a plain string until this runs.
  wrap =
    cmd:
    if builtins.isList cmd then
      mkLuaInline ''
        function()
          ${concatMapStringsSep "\n  " (c: c) cmd}
        end
      ''
    else
      mkLuaInline cmd;

  # A bind value is either a bare dispatcher (string or list of strings,
  # for combining several), or { cmd; flags; } when it needs flags.
  normalizeBind =
    v:
    if builtins.isAttrs v then
      {
        inherit (v) cmd;
        flags = lib.toList (v.flags or [ ]);
      }
    else
      {
        cmd = v;
        flags = [ ];
      };

  # helper for groups that all share the same flag (mouse/locked/repeating).
  # Operates on an attrset of key -> bind value now, not a list.
  withFlags =
    flags:
    builtins.mapAttrs (
      _: v:
      let
        n = normalizeBind v;
      in
      {
        inherit (n) cmd;
        flags = n.flags ++ lib.toList flags;
      }
    );

  # -- mkBinds: attrset of "key combo string" -> dispatcher (or { cmd; flags; })
  # becomes the list of _args tables home-manager turns into hl.bind(...) calls.
  # Because it's a real attrset, accidentally writing the same key combo twice
  # in one literal is now a hard Nix eval error instead of Hyprland silently
  # getting two competing binds.
  mkBinds =
    binds:
    lib.mapAttrsToList (
      key: v:
      let
        n = normalizeBind v;
      in
      {
        _args = [
          key
          (wrap n.cmd)
        ]
        ++ n.flags;
      }
    ) binds;

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
    mkBinds (
      builtins.foldl' (
        acc: x:
        let
          n = x + 1;
          # map 10 -> "0" to match a typical top-row key
          c = n / 10;
          keyName = toString (n - (c * 10));
        in
        acc
        // {
          "${mod} + ${keyName}" =
            focus.workspace n;
          "${shiftMod} + ${keyName}" =
            window.moveToWorkspace n;
        }
      ) { } (builtins.genList (x: x) count)
    );
}
