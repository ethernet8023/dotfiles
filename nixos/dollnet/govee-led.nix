{ lib
, buildHomeAssistantComponent
, fetchFromGitHub
}:

buildHomeAssistantComponent {
  owner = "eimirae";
  domain = "govee-ble-lights";
  version = "unstable-2023-11-21";

  src = fetchFromGitHub {
    owner = "eimirae";
    repo = "govee_ble_lights";
    rev = "87a80b461c6d4f483d6c6c6d5e972e59927ec7d5";
    hash = "sha256-yAuN8aGnUZpuJGfHRI5C7CyFtgpMT/ym9s0xPqIIJIs=";
  };

  dontBuild = true;

  propagatedBuildInputs = [];

  doCheck = false;

  meta = with lib; {
    description = "Home Assistant integration for Govee BLE lights";
    homepage = "https://github.com/eimirae/govee_ble_lights";
  };
}
