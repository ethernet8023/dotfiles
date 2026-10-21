# ssh keys: the per-machine USER keys -- the id_ed25519 generated on each box,
# used for machine->machine auth. every machine in `mesh` authorizes all of
# `mesh` (see nixos/all-systems-configuration.nix), so any host entry in
# home-manager/ssh.nix works from any machine.
rec {
  # ── user keys ──
  luna = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIL+5IDeIKvYpQllVsU/soRu27KyPTA5FXvZM5Z8+ms7 arilotter@gmail.com";
  hermes = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMKaPWTrDp1sp3NUXiM/JXKfivQQ6TLxMy7Fyaq59L7y arilotter@gmail.com";
  iris = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGACmqQ07rrYy2g8cjCkLeVkiBRfqFD1EwF27+AU0He+ arilotter@gmail.com";

  # spark pair -- DGX OS, not nix-managed; keys live on the boxes
  phobos = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGrtDI7PSYW4TsBb9wJAqdyFRCDmJgr25hz3F50Yo36k ethernet@spark-73e5";

  deimos = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILpaGqpz3+FJi2hOUqpZ+dKOqGk81Xl5TU6nX6F73Ts4 ethernet@spark-7a30";

  # promise -- windows arm64; keypair generated on the box
  promise = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILdhWXhyj4XlpWsgtdhnVQoRsePkekikby69I1NNI1l4 arilotter@gmail.com";

  # ethernet's USER key on bellona
  bellona-user = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII07YJjVEXOI7taW500PJ1j6hPI+mHoJNWxXG90/6SL+ arilotter@gmail.com";

  # window (windows box, user laser) was offline at last edit; when it's up:
  #   ssh -F none laser@window.local "powershell -NoProfile -Command Get-Content ~/.ssh/id_ed25519.pub"
  # then add it here AND to `mesh`.

  # ── external / shared keys ──
  android = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOUl42TMh18ALGzChA0v1BQ6vzOJYmqt3EdFeuMaS0vD";
  nous-eng = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGifAl2SGcrIZEHkV6hm+zJ7DfyE3Q4MJcqCR0hWgqE5 engineering@nousresearch.com";

  # ── categories ──
  # the mesh: authorized on every machine in it (nixos boxes add
  # android + nous-eng on top).
  mesh = [
    luna
    hermes
    iris
    phobos
    deimos
    promise
    bellona-user
  ];

  # agenix recipients: th desktops/laptops
  home-devices = [
    luna
    hermes
    iris
  ];
}
