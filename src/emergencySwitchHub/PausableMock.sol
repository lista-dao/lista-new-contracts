import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

contract PausableMock is Pausable {
  address public immutable emergencySwitchHub;
  string public name;

  modifier onlyEmergencySwitchHub() {
    require(msg.sender == emergencySwitchHub, "PausableMock/not-EmergencySwitchHub");
    _;
  }

  constructor(string memory _name, address _emergencySwitchHub) {
    name = _name;
    emergencySwitchHub = _emergencySwitchHub;
  }

  function pause() external onlyEmergencySwitchHub {
    _pause();
  }

  function unpause() external onlyEmergencySwitchHub {
    _unpause();
  }
}
