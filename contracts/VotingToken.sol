// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract VotingToken is ERC20 {
    address public votingContract;

    constructor() ERC20("Voting DAO Token", "VDT") {
        votingContract = msg.sender;
    }

    modifier onlyVotingContract() {
        require(msg.sender == votingContract, "Not the voting contract");
        _;
    }

    function mint(address _to, uint256 _amount) external onlyVotingContract {
        _mint(_to, _amount);
    }

    function burn(address _from, uint256 _amount) external onlyVotingContract {
        _burn(_from, _amount);
    }
}