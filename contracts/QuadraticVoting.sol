// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "./IExecutableProposal.sol";
import "./VotingToken.sol";

/* QuadraticVoting Contract
   All state variables were organized to minimize slot usage in storage.

   Public functions:
*/
contract QuadraticVoting {
    enum VotingState { CLOSED, OPEN }
    enum ProposalState { PENDING, APPROVED, REJECTED, CANCELED, SIGNALFIN, UNKNOWN }

    struct Participant {
        uint tokensOwned;
        bool registered;
        bool active;
    }

    /*
    * PENDING   = !approved && !canceled && period == currentPeriod
    * APPROVED  = approved (When a proposal is approved it is implicitly executed)
    * REJECTED  = !approved && !canceled && period < currentPeriod
    * CANCELED  = canceled
    * SIGNALFIN = budget == 0 && !canceled && period < currentPeriod
    */
    struct Proposal {
        string title;
        string description;

        uint budget;
        uint votes;
        uint tokensStaked;
        uint period;

        address executable;
        address proposer;

        bool approved;
        bool canceled;
        bool executed;
    }

    mapping(address => Participant) private participants;
    mapping(uint => Proposal) private proposals;
    mapping(address => mapping(uint => uint)) private votes;
    mapping(address => mapping(uint => uint)) private tokensStakedPerProposal;

    uint public totalBudget;
    uint public numParticipants;
    uint private numPendingProposals;
    uint private nextProposalId;
    uint public currentPeriod;

    uint[] private pendingProposalsList;
    uint[] private approvedProposalsList;
    uint[] private signalingProposalsList;
    mapping(uint => uint) private proposalToIdx;

    ERC20 private token;
    uint public tokenPrice;
    uint public maxTokens;

    address public owner;
    VotingState public state;

    bool private lock = false;

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

    modifier onlyProposer(uint _id) {
        require(proposals[_id].proposer == msg.sender, "Only the proposer can execute this proposal");
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

    function _add(uint[] storage list, uint _id) internal {
        proposalToIdx[_id] = list.length;
        list.push(_id);
    }

    function _remove(uint[] storage list, uint _id) internal {
        uint first = proposalToIdx[_id];
        uint last = list.length - 1;
        uint lastId = list[last];

        list[first] = lastId;
        proposalToIdx[lastId] = first;

        list.pop();
        delete proposalToIdx[_id];
    }

    function _addPending(uint _id) internal {
        _add(pendingProposalsList, _id);
    }

    function _addApproved(uint _id) internal {
        _add(approvedProposalsList, _id);
    }

    function _addSignaling(uint _id) internal {
        _add(signalingProposalsList, _id);
    }

    function _removePending(uint _id) internal {
        _remove(pendingProposalsList, _id);
    }

    function _removeSignaling(uint _id) internal {
        _remove(signalingProposalsList, _id);
    }

    function _checksThreshold(uint _id) internal view returns (bool) {
        Proposal storage prop = proposals[_id];
        uint th = (((20 + (prop.budget * 100) / totalBudget) * numParticipants) / 100) + numPendingProposals;
        return (prop.votes >= th) && (prop.budget > 0);
    }

    function _checkAndExecuteProposal(uint _id) internal {
        require(!lock, "Execution is locked right now"); // just in case, we don't want reentrancy
        if(_checksThreshold(_id)) {
            Proposal storage prop = proposals[_id];
            prop.approved = true;
            prop.executed = true;

            _removePending(_id);
            _addApproved(_id);

            lock = true; // reentrancy lock

            uint addBudget = prop.tokensStaked * tokenPrice;
            totalBudget += addBudget; // tokens staked to the proposal contribute to the global budget
            require(totalBudget >= prop.budget, "Total Budget is not enough to execute this proposal."); // underflow check
            totalBudget -= prop.budget; // budget from the proposal is used

            _burnTokens(address(this), prop.tokensStaked);

            lock = false;

            IExecutableProposal(prop.executable).executeProposal{value: prop.budget}(
                _id,
                prop.votes,
                prop.tokensStaked
            );
        }
    }

    function _calculateProposalState(uint _id) internal view returns (ProposalState) {
        Proposal storage prop = proposals[_id];
        if (bytes(prop.title).length == 0) return ProposalState.UNKNOWN;
        ProposalState propState = ProposalState.APPROVED;
        if (!prop.approved && !prop.canceled && prop.period == currentPeriod) // PENDING
            propState = ProposalState.PENDING;
        else if (!prop.approved && !prop.canceled && prop.period < currentPeriod) // REJECTED
            propState = ProposalState.REJECTED;
        else if (prop.canceled) // CANCELED
            propState = ProposalState.CANCELED;
        else if (prop.budget == 0 && !prop.canceled && prop.period < currentPeriod) // SIGNALING PROPOSAL FINISHED
            propState = ProposalState.SIGNALFIN;
        return propState;
    }

    function openVoting() external payable onlyOwner inState(VotingState.CLOSED) {
        totalBudget = msg.value;
        state = VotingState.OPEN;

        delete pendingProposalsList;
        delete approvedProposalsList;
        delete signalingProposalsList;
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

    function removeParticipant() external onlyActiveParticipant {
        Participant storage p = participants[msg.sender];

        p.active = false;
        --numParticipants;
    }

    function addProposal(string memory _title, string memory _description, uint _budget, address _executable)
    external
    onlyActiveParticipant
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
            tokensStaked: 0,
            period: currentPeriod, 
            approved: false,
            canceled: false,
            executed: false,
            executable: _executable,
            proposer: msg.sender
        });

        if (_budget > 0) {
            ++numPendingProposals;
            _addPending(proposalId);
        } else {
            _addSignaling(proposalId);
        }

        return proposalId;
    }

    function cancelProposal(uint proposalId) external inState(VotingState.OPEN) {
        Proposal storage prop = proposals[proposalId];

        require(msg.sender == prop.proposer, "Only the creator of the proposal can cancel it");
        require(!prop.approved, "Can't cancel a proposal that's already approved");
        require(!prop.canceled, "The proposal is already cancel");

        if (prop.budget > 0) {
            --numPendingProposals;
            _removePending(proposalId);
        } else _removeSignaling(proposalId);
        prop.canceled = true;
    }

    function claimTokensRefund(uint proposalId) external onlyActiveParticipant {
        ProposalState propState = _calculateProposalState(proposalId);
        bool requirementState = propState == ProposalState.REJECTED || propState == ProposalState.CANCELED || propState == ProposalState.SIGNALFIN;
        require(requirementState, "The proposal you tried to claim from is either still up for voting, or is a signaling proposal during an open voting period");
        
        uint amount = tokensStakedPerProposal[msg.sender][proposalId];
        require(amount > 0, "No tokens to refund");

        // Pull the amount of tokens to refund
        tokensStakedPerProposal[msg.sender][proposalId] = 0;
        token.transfer(msg.sender, amount);
    }

    function buyTokens() external payable onlyActiveParticipant {
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

        (bool success, ) = payable(msg.sender).call{value: etherToReturn}("");
        require(success, "ETH transfer failed");
    }

    function getERC20() external view returns(address) {
        return address(token);
    }

    function getPendingProposals() external view inState(VotingState.OPEN) returns (uint[] memory) {
        return pendingProposalsList;
    }

    function getApprovedProposals() external view inState(VotingState.OPEN) returns (uint[] memory) {
        return approvedProposalsList;
    }

    function getSignalingProposals() external view inState(VotingState.OPEN) returns (uint[] memory) {
        return signalingProposalsList;
    }

    function getProposalInfo(uint _id) external view inState(VotingState.OPEN) returns (Proposal memory) {
        require(_id < nextProposalId, "Invalid ID");
        Proposal memory p = proposals[_id];
        return p;
    }

    function stake(uint _proposalId, uint _votes) external inState(VotingState.OPEN) onlyActiveParticipant {
        require(_votes > 0, "You need at least 1 vote");

        ProposalState propState = _calculateProposalState(_proposalId);
        require(propState == ProposalState.PENDING, "This proposal cannot be voted");
        
        uint currentVotes = votes[msg.sender][_proposalId];
        uint newVotes = currentVotes + _votes;

        // find the amount of extra tokens we need to pay for v^2
        // IMPORTANT NOT TO THINK THIS IS THAT EACH VOTE WE ADD MAKES IT
        // QUADRATICALLY MORE EXPENSIVE (I almost did that)
        uint costToVote = (newVotes * newVotes) - (currentVotes * currentVotes);
        require(participants[msg.sender].tokensOwned >= costToVote, "Insufficient tokens to vote");

        participants[msg.sender].tokensOwned -= costToVote;
        votes[msg.sender][_proposalId] = newVotes;
        proposals[_proposalId].votes += _votes;
        proposals[_proposalId].tokensStaked += costToVote;
        tokensStakedPerProposal[msg.sender][_proposalId] += costToVote;
        token.transferFrom(msg.sender, address(this), costToVote);

        _checkAndExecuteProposal(_proposalId);
    }

    function withdrawFromProposal(uint _proposalId, uint _votes) external inState(VotingState.OPEN) onlyActiveParticipant {
        require(_votes > 0, "You need at least 1 vote");

        ProposalState propState = _calculateProposalState(_proposalId);
        require(propState == ProposalState.PENDING, "This proposal cannot be voted");

        uint currentVotes = votes[msg.sender][_proposalId];
        require(currentVotes > 0, "You didn't vote to this proposal yet");
        require(currentVotes >= _votes, "You can't withdraw more votes than you have");

        /* we have v votes. We want to get rid of n votes, so we end up with v - n votes
        *  if we had v^2 tokens, and we end up with (v-n)^2 tokens, that means we need
        *  to refund v^2 - (v-n)^2 tokens
        */
        uint votesAfter = currentVotes - _votes;
        uint tokensToRefund = (currentVotes * currentVotes) - (votesAfter * votesAfter);

        participants[msg.sender].tokensOwned += tokensToRefund;
        votes[msg.sender][_proposalId] = votesAfter;
        proposals[_proposalId].votes -= _votes;
        tokensStakedPerProposal[msg.sender][_proposalId] -= tokensToRefund;
        token.transfer(msg.sender, tokensToRefund);
    }

    function closeVoting() external onlyOwner inState(VotingState.OPEN) {
        state = VotingState.CLOSED;
        ++currentPeriod; // this will immediately reject those proposals that were not approved

        // Since this is pull over push we don't really need to do anything more with
        // proposals since all refunds are up to the clients
        // Also, executing signaling proposals is now a reponsibility of the proposer
        uint refundBudget = totalBudget;
        totalBudget = 0; // avoid reentrancy
        (bool success, ) = payable(owner).call{value: refundBudget}("");
        require(success, "Budget transfer failed");
    }

    function executeSignaling(uint _id) external onlyProposer(_id) {
        Proposal storage prop = proposals[_id];
        ProposalState propState = _calculateProposalState(_id);

        require(propState == ProposalState.SIGNALFIN, "You can't execute this signaling proposal");
        require(!prop.executed, "This proposal was already executed");

        IExecutableProposal executable =
        IExecutableProposal(prop.executable);

        prop.executed = true;

        executable.executeProposal(
            _id,
            prop.votes,
            prop.tokensStaked
        );
    }
}