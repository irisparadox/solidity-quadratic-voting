// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract QuadraticVoting {
    enum VotingState { CLOSED, OPEN }

    struct Participant {
        bool registered;
        uint tokensOwned;
    }

    struct Proposal {
        string title;
        uint budget;
        uint votes;
        bool approved;
        bool canceled;
        bool isSignaling;
        address executable;
    }

    mapping(address => Participant) public participants;
    mapping(uint => Proposal) public proposals;
    mapping(address => mapping(uint => uint)) public votes;

    uint public totalBudget;
    uint public numParticipants;
    uint public nextProposalId;

    /* Data structures to store requests of retrieval of Tokens
     * and Ether from the contract.
     */
    mapping(address => uint) public pendingTokenRetrieval;
    mapping(address => uint) public pendingEtherRetrieval;

    VotingState public state;

    constructor() {
        state = VotingState.CLOSED;
    }
}