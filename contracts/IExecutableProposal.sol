// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IExecutableProposal {
    function executeProposal(uint proposalId, uint numVotes, uint numTokens) external payable;
}