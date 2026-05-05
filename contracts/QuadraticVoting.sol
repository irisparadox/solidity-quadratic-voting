// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract QuadraticVoting {
    enum VotingState { CLOSED, OPEN }

    struct Participant {
        bool registered;
        bool active;
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

    ERC20 public token;
    uint public tokenPrice;
    uint public maxTokens;

    VotingState public state;
    address public owner;

    constructor(uint _tokenPrice, uint _maxTokens) {
        owner = msg.sender;
        state = VotingState.CLOSED;

        tokenPrice = _tokenPrice;
        maxTokens = _maxTokens;

        // token = new ERC20();
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier inState(VotingState s) {
        require(state == s, "Invalid state");
        _;
    }

    modifier onlyParticipant() {
        require(participants[msg.sender].registered, "Not a participant");
        _;
    }

    modifier onlyActiveParticipant() {
        require(
            participants[msg.sender].registered &&
            participants[msg.sender].active,
            "Not active participant"
        );
        _;
    }

    function openVoting() external payable onlyOwner inState(VotingState.CLOSED) {
        totalBudget = msg.value;
        state = VotingState.OPEN;
    }

    function addParticipant() external payable {
        require(!participants[msg.sender].registered, "Participant is already registered");
        require(msg.value >= tokenPrice, "Not enough Ether");

        uint tokensToMint = msg.value / tokenPrice;

        participants[msg.sender] = Participant({
            registered: true,
            active: true,
            tokensOwned: tokensToMint
        });

        ++numParticipants;
        //token.mint(msg.sender, tokensToMint);
    }

    function removeParticipant() external onlyParticipant() {
        Participant storage p = participants[msg.sender];
        require(p.active, "Participant was already removed");
        p.active = false;
    }

    function addProposal(string memory title, uint budget, address executable)
        external
        onlyParticipant()
        inState(VotingState.OPEN) {
            proposals[nextProposalId++] = Proposal({
                title: title,
                budget: budget,
                votes: 0,
                approved: false,
                canceled: false,
                isSignaling: budget == 0,
                executable: executable
            });
        }
}