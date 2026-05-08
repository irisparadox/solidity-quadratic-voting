// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "./IExecutableProposal.sol";

contract EchoProposal is IExecutableProposal, ERC165 {

    event ProposalExecuted(
        uint proposalId,
        uint votes,
        uint tokens,
        uint contractBalance
    );

    function executeProposal(
        uint proposalId,
        uint numVotes,
        uint numTokens
    ) external payable override {
        emit ProposalExecuted(
            proposalId,
            numVotes,
            numTokens,
            address(this).balance
        );
    }

    function getBalance() external view returns (uint) {
        return address(this).balance;
    }

    receive() external payable {}

    // ERC165 support check
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override
        returns (bool)
    {
        return interfaceId == type(IExecutableProposal).interfaceId
            || super.supportsInterface(interfaceId);
    }
}