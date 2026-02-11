rec {
  luna = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIL+5IDeIKvYpQllVsU/soRu27KyPTA5FXvZM5Z8+ms7 arilotter@gmail.com";
  hermes = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMKaPWTrDp1sp3NUXiM/JXKfivQQ6TLxMy7Fyaq59L7y arilotter@gmail.com";
  sol = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL7Yhctas2HcsJeAa82xj7uMcIa3GWJuhwFPKO9qke93 arilotter@gmail.com";
  casey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICnDDh2c4TfMLowUo3r3zAmKKeDHWtwUubi4Ml9sD4TJ arilotter@gmail.com";
  android = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOUl42TMh18ALGzChA0v1BQ6vzOJYmqt3EdFeuMaS0vD";

  nous-eng = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGifAl2SGcrIZEHkV6hm+zJ7DfyE3Q4MJcqCR0hWgqE5 engineering@nousresearch.com";
  home-devices = [
    luna
    hermes
    sol
  ];

  physically-safe-devices = home-devices ++ [ casey ];
}
