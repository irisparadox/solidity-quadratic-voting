// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "./IExecutableProposal.sol";
import "./VotingToken.sol";

contract QuadraticVoting {
    enum VotingState { CLOSED, OPEN }

    struct Participant {
        bool registered;
        bool active;
        uint tokensOwned;
    }

    struct Proposal {
        string title;
        string description;
        uint budget;
        uint votes;
        bool approved;
        bool canceled;
        bool isSignaling;
        address executable;
        address proposer;
    }

    mapping(address => Participant) public participants;
    mapping(uint => Proposal) public proposals;
    mapping(address => mapping(uint => uint)) public votes;
    mapping(address => mapping(uint => uint)) public tokensStakedPerProposal;

    uint public totalBudget;
    uint public numParticipants;
    uint public numPendingProposals;
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

        // address(this) is the votingContract inside the token
        token = new VotingToken();
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier inState(VotingState s) {
        require(state == s, "Invalid state");
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

    function _mintTokens(address _to, uint256 _amount) internal {
        VotingToken(address(token)).mint(_to, _amount);
    }

    function _burnTokens(address _from, uint256 _amount) internal {
        VotingToken(address(token)).burn(_from, _amount);
    }

    function openVoting() external payable onlyOwner inState(VotingState.CLOSED) {
        totalBudget = msg.value;
        state = VotingState.OPEN;
    }

    function addParticipant() external payable {
        Participant storage p = participants[msg.sender];
        require(!p.active, "Account is already an active participant");

        uint256 tokensToMint = msg.value / tokenPrice; // calc n tokens
        require(tokensToMint >= 1, "You must be able to buy at least one token to register");

        require(token.totalSupply() + tokensToMint <= maxTokens, "Maximum number of tokens has been reached");

        if (!p.registered) {
            p.registered = true; // user registered for the first time
        }

        // register user
        p.active = true;
        p.tokensOwned += tokensToMint;
        ++numParticipants;

        _mintTokens(msg.sender, tokensToMint);
    }

    function removeParticipant() external onlyActiveParticipant() {
        Participant storage p = participants[msg.sender];

        p.active = false;
        --numParticipants;
    }

    function addProposal(string memory _title, string memory _description, uint _budget, address _executable)
    external
    onlyActiveParticipant()
    inState(VotingState.OPEN)
    returns (uint) {
        // IERC165 Check
        /* Source: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/introspection/IERC165.sol
        *  We check if the proposal executable is implemented using the IExecutableProposal interface using IERC165
        */
        require(
            IERC165(_executable).supportsInterface(type(IExecutableProposal).interfaceId),
            "Executable contract is invalid. It does not implement IExecutableProposal"
        );
        uint proposalId = nextProposalId++;
        proposals[proposalId] = Proposal({
            title: _title,
            description: _description,
            budget: _budget,
            votes: 0,
            approved: false,
            canceled: false,
            isSignaling: _budget == 0,
            executable: _executable,
            proposer: msg.sender
        });

        if (_budget > 0) ++numPendingProposals;

        return proposalId;
    }

    function cancelProposal(uint proposalId) external inState(VotingState.OPEN) {
        Proposal storage prop = proposals[proposalId];

        require(msg.sender == prop.proposer, "Only the creator of the proposal can cancel it");
        require(!prop.approved, "Can't cancel a proposal that's already approved");
        require(!prop.canceled, "The proposal is already cancel");

        if (!prop.isSignaling) --numPendingProposals;
        prop.canceled = true;
    }

    function claimTokensRefund(uint proposalId) external {
        Proposal storage prop = proposals[proposalId];

        // Either the proposal was canceled, or the voting state is closed but the proposal wasn't approved
        require(prop.canceled || (state == VotingState.CLOSED && !prop.approved), "Can't claim tokens for this proposal");
        
        uint amount = tokensStakedPerProposal[msg.sender][proposalId];
        require(amount > 0, "No tokens to refund");

        // Pull the amount of tokens to refund
        tokensStakedPerProposal[msg.sender][proposalId] = 0;
        pendingTokenRetrieval[msg.sender] += amount;
    }

    function withdrawTokens() external {
        uint amount = pendingTokenRetrieval[msg.sender];
        require(amount > 0, "Nothing to withdraw");

        pendingTokenRetrieval[msg.sender] = 0;
        require(token.transfer(msg.sender, amount), "Error during the transfer");
    }

    function buyTokens() external payable onlyActiveParticipant() {
        require(msg.value > 0, "You need to send Ether in order to buy tokens");

        // tokens to mint
        uint256 tokensToMint = msg.value / tokenPrice;
        require(tokensToMint > 0, "Inssuficient funds to buy tokens");

        require(token.totalSupply() + tokensToMint <= maxTokens, "Maximum number of tokens has been reached");

        participants[msg.sender].tokensOwned += tokensToMint;
        _mintTokens(msg.sender, tokensToMint);
    }

    function sellTokens(uint numTokens) external onlyActiveParticipant {
        require(token.balanceOf(msg.sender) >= numTokens, "You don't have enough tokens");

        uint etherToReturn = numTokens * tokenPrice;
        _burnTokens(msg.sender, numTokens);

        pendingEtherRetrieval[msg.sender] += etherToReturn;
    } 
}