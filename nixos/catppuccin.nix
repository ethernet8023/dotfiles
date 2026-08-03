{ ... }:
{
  catppuccin = {
    # enable is becoming a global on/off switch, with autoEnable deciding
    # whether ports get enrolled automatically. spelling both out keeps
    # today's behaviour (everything themed) and silences the deprecation.
    enable = true;
    autoEnable = true;
    cursors.enable = true;
    flavor = "mocha";
    accent = "lavender";
  };
}
