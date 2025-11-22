// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title CrowdfundingEscrow
 * @notice Escrow-based crowdfunding for campus projects on Avalanche C-Chain
 * @dev Handles campaign creation, donations in AVAX, milestone-based fund releases,
 *      donor voting, and refunds. All amounts displayed in KES but stored in AVAX.
 */

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CrowdfundingEscrow is ReentrancyGuard, Ownable {
    
    // ============ Structs ============
    
    struct Milestone {
        string description;
        uint256 amountKES;          // Amount in KES for display
        uint256 amountAVAX;         // Amount in AVAX (calculated at creation)
        bool released;              // Whether funds have been released
        uint256 votesFor;           // Number of donors voting to release
        uint256 votesAgainst;       // Number of donors voting against
        mapping(address => bool) hasVoted;
        string evidenceURI;         // IPFS or external link to evidence
        uint256 proposedAt;         // Timestamp of proposal
    }
    
    struct Campaign {
        address creator;
        string title;
        string description;
        uint256 goalKES;            // Campaign goal in KES
        uint256 goalAVAX;           // Campaign goal in AVAX (converted at creation)
        uint256 deadline;           // Unix timestamp
        uint256 totalDonationsAVAX; // Total donated in AVAX
        uint256 conversionRate;     // KES per AVAX at creation time
        uint256 conversionTimestamp;// When conversion was calculated
        bool goalReached;
        bool finalized;             // Campaign completed (success or refund)
        uint256 milestonesCount;
        mapping(uint256 => Milestone) milestones;
        mapping(address => uint256) donations; // donor => amount in AVAX
        address[] donorList;
        uint256 createdAt;
    }
    
    // ============ State Variables ============
    
    uint256 public campaignCounter;
    mapping(uint256 => Campaign) public campaigns;
    
    // Voting parameters
    uint256 public constant VOTE_THRESHOLD_PERCENT = 50; // 50% approval needed
    uint256 public constant MIN_VOTE_QUORUM_PERCENT = 30; // 30% of donors must vote
    
    // ============ Events ============
    
    event CampaignCreated(
        uint256 indexed campaignId,
        address indexed creator,
        string title,
        uint256 goalKES,
        uint256 goalAVAX,
        uint256 conversionRate,
        uint256 deadline,
        uint256 milestonesCount
    );
    
    event DonationReceived(
        uint256 indexed campaignId,
        address indexed donor,
        uint256 amountAVAX,
        uint256 amountKES,
        uint256 totalDonationsAVAX
    );
    
    event MilestoneProposed(
        uint256 indexed campaignId,
        uint256 indexed milestoneIndex,
        string evidenceURI,
        uint256 proposedAt
    );
    
    event VoteCast(
        uint256 indexed campaignId,
        uint256 indexed milestoneIndex,
        address indexed voter,
        bool approve,
        uint256 votesFor,
        uint256 votesAgainst
    );
    
    event MilestoneFinalized(
        uint256 indexed campaignId,
        uint256 indexed milestoneIndex,
        uint256 amountAVAX,
        uint256 amountKES,
        address recipient
    );
    
    event RefundIssued(
        uint256 indexed campaignId,
        address indexed donor,
        uint256 amountAVAX
    );
    
    event FundsWithdrawn(
        uint256 indexed campaignId,
        address indexed recipient,
        uint256 amountAVAX
    );
    
    // ============ Modifiers ============
    
    modifier campaignExists(uint256 _campaignId) {
        require(_campaignId < campaignCounter, "Campaign does not exist");
        _;
    }
    
    modifier onlyCampaignCreator(uint256 _campaignId) {
        require(
            campaigns[_campaignId].creator == msg.sender,
            "Only campaign creator can call this"
        );
        _;
    }
    
    modifier campaignActive(uint256 _campaignId) {
        Campaign storage campaign = campaigns[_campaignId];
        require(!campaign.finalized, "Campaign already finalized");
        require(block.timestamp < campaign.deadline, "Campaign deadline passed");
        _;
    }
    
    modifier isDonor(uint256 _campaignId) {
        require(
            campaigns[_campaignId].donations[msg.sender] > 0,
            "Not a donor to this campaign"
        );
        _;
    }
    
    // ============ Constructor ============
    
    constructor() Ownable(msg.sender) {}
    
    // ============ Campaign Management ============
    
    /**
     * @notice Create a new crowdfunding campaign
     * @param _title Campaign title
     * @param _description Campaign description
     * @param _goalKES Goal amount in KES (for display)
     * @param _goalAVAX Goal amount in AVAX (calculated off-chain with conversion)
     * @param _conversionRate KES per AVAX at creation time (e.g., 146500)
     * @param _deadline Unix timestamp for campaign deadline
     * @param _milestoneDescriptions Array of milestone descriptions
     * @param _milestoneAmountsKES Array of milestone amounts in KES
     * @param _milestoneAmountsAVAX Array of milestone amounts in AVAX
     */
    function createCampaign(
        string memory _title,
        string memory _description,
        uint256 _goalKES,
        uint256 _goalAVAX,
        uint256 _conversionRate,
        uint256 _deadline,
        string[] memory _milestoneDescriptions,
        uint256[] memory _milestoneAmountsKES,
        uint256[] memory _milestoneAmountsAVAX
    ) external returns (uint256) {
        require(_deadline > block.timestamp, "Deadline must be in the future");
        require(_goalAVAX > 0, "Goal must be greater than 0");
        require(
            _milestoneDescriptions.length == _milestoneAmountsKES.length &&
            _milestoneAmountsKES.length == _milestoneAmountsAVAX.length,
            "Milestone arrays length mismatch"
        );
        require(_milestoneDescriptions.length > 0, "At least one milestone required");
        
        uint256 campaignId = campaignCounter++;
        Campaign storage campaign = campaigns[campaignId];
        
        campaign.creator = msg.sender;
        campaign.title = _title;
        campaign.description = _description;
        campaign.goalKES = _goalKES;
        campaign.goalAVAX = _goalAVAX;
        campaign.deadline = _deadline;
        campaign.conversionRate = _conversionRate;
        campaign.conversionTimestamp = block.timestamp;
        campaign.milestonesCount = _milestoneDescriptions.length;
        campaign.createdAt = block.timestamp;
        
        // Create milestones
        for (uint256 i = 0; i < _milestoneDescriptions.length; i++) {
            Milestone storage milestone = campaign.milestones[i];
            milestone.description = _milestoneDescriptions[i];
            milestone.amountKES = _milestoneAmountsKES[i];
            milestone.amountAVAX = _milestoneAmountsAVAX[i];
        }
        
        emit CampaignCreated(
            campaignId,
            msg.sender,
            _title,
            _goalKES,
            _goalAVAX,
            _conversionRate,
            _deadline,
            _milestoneDescriptions.length
        );
        
        return campaignId;
    }
    
    /**
     * @notice Donate AVAX to a campaign
     * @param _campaignId ID of the campaign to donate to
     */
    function donate(uint256 _campaignId)
        external
        payable
        campaignExists(_campaignId)
        campaignActive(_campaignId)
        nonReentrant
    {
        require(msg.value > 0, "Donation must be greater than 0");
        
        Campaign storage campaign = campaigns[_campaignId];
        
        // Record donation
        if (campaign.donations[msg.sender] == 0) {
            campaign.donorList.push(msg.sender);
        }
        campaign.donations[msg.sender] += msg.value;
        campaign.totalDonationsAVAX += msg.value;
        
        // Check if goal reached
        if (campaign.totalDonationsAVAX >= campaign.goalAVAX) {
            campaign.goalReached = true;
        }
        
        // Calculate KES equivalent for event
        uint256 amountKES = (msg.value * campaign.conversionRate) / 1e18;
        
        emit DonationReceived(
            _campaignId,
            msg.sender,
            msg.value,
            amountKES,
            campaign.totalDonationsAVAX
        );
    }
    
    // ============ Milestone Management ============
    
    /**
     * @notice Propose a milestone release with evidence
     * @param _campaignId Campaign ID
     * @param _milestoneIndex Index of the milestone
     * @param _evidenceURI Link to evidence (IPFS, Google Drive, etc.)
     */
    function proposeMilestoneRelease(
        uint256 _campaignId,
        uint256 _milestoneIndex,
        string memory _evidenceURI
    )
        external
        campaignExists(_campaignId)
        onlyCampaignCreator(_campaignId)
    {
        Campaign storage campaign = campaigns[_campaignId];
        require(_milestoneIndex < campaign.milestonesCount, "Invalid milestone index");
        require(campaign.goalReached, "Campaign goal not reached");
        
        Milestone storage milestone = campaign.milestones[_milestoneIndex];
        require(!milestone.released, "Milestone already released");
        require(milestone.proposedAt == 0, "Milestone already proposed");
        
        milestone.evidenceURI = _evidenceURI;
        milestone.proposedAt = block.timestamp;
        
        emit MilestoneProposed(_campaignId, _milestoneIndex, _evidenceURI, block.timestamp);
    }
    
    /**
     * @notice Vote on a proposed milestone release
     * @param _campaignId Campaign ID
     * @param _milestoneIndex Milestone index
     * @param _approve True to approve, false to reject
     */
    function voteOnMilestone(
        uint256 _campaignId,
        uint256 _milestoneIndex,
        bool _approve
    )
        external
        campaignExists(_campaignId)
        isDonor(_campaignId)
    {
        Campaign storage campaign = campaigns[_campaignId];
        require(_milestoneIndex < campaign.milestonesCount, "Invalid milestone index");
        
        Milestone storage milestone = campaign.milestones[_milestoneIndex];
        require(milestone.proposedAt > 0, "Milestone not proposed yet");
        require(!milestone.released, "Milestone already released");
        require(!milestone.hasVoted[msg.sender], "Already voted");
        
        milestone.hasVoted[msg.sender] = true;
        
        if (_approve) {
            milestone.votesFor++;
        } else {
            milestone.votesAgainst++;
        }
        
        emit VoteCast(
            _campaignId,
            _milestoneIndex,
            msg.sender,
            _approve,
            milestone.votesFor,
            milestone.votesAgainst
        );
    }
    
    /**
     * @notice Finalize and release milestone funds if voting threshold met
     * @param _campaignId Campaign ID
     * @param _milestoneIndex Milestone index
     */
    function finalizeMilestone(
        uint256 _campaignId,
        uint256 _milestoneIndex
    )
        external
        campaignExists(_campaignId)
        nonReentrant
    {
        Campaign storage campaign = campaigns[_campaignId];
        require(_milestoneIndex < campaign.milestonesCount, "Invalid milestone index");
        
        Milestone storage milestone = campaign.milestones[_milestoneIndex];
        require(milestone.proposedAt > 0, "Milestone not proposed");
        require(!milestone.released, "Milestone already released");
        
        // Check voting results
        uint256 totalVotes = milestone.votesFor + milestone.votesAgainst;
        uint256 donorCount = campaign.donorList.length;
        
        require(
            totalVotes * 100 >= donorCount * MIN_VOTE_QUORUM_PERCENT,
            "Minimum quorum not reached"
        );
        
        require(
            milestone.votesFor * 100 >= totalVotes * VOTE_THRESHOLD_PERCENT,
            "Approval threshold not met"
        );
        
        // Release funds
        milestone.released = true;
        uint256 releaseAmount = milestone.amountAVAX;
        
        require(
            address(this).balance >= releaseAmount,
            "Insufficient contract balance"
        );
        
        (bool success, ) = campaign.creator.call{value: releaseAmount}("");
        require(success, "Transfer failed");
        
        emit MilestoneFinalized(
            _campaignId,
            _milestoneIndex,
            releaseAmount,
            milestone.amountKES,
            campaign.creator
        );
    }
    
    // ============ Refund Management ============
    
    /**
     * @notice Request refund if campaign failed (deadline passed and goal not reached)
     * @param _campaignId Campaign ID
     */
    function requestRefund(uint256 _campaignId)
        external
        campaignExists(_campaignId)
        isDonor(_campaignId)
        nonReentrant
    {
        Campaign storage campaign = campaigns[_campaignId];
        require(block.timestamp >= campaign.deadline, "Campaign still active");
        require(!campaign.goalReached, "Campaign goal was reached");
        
        uint256 donationAmount = campaign.donations[msg.sender];
        require(donationAmount > 0, "No donation to refund");
        
        campaign.donations[msg.sender] = 0;
        
        (bool success, ) = msg.sender.call{value: donationAmount}("");
        require(success, "Refund transfer failed");
        
        emit RefundIssued(_campaignId, msg.sender, donationAmount);
    }
    
    // ============ View Functions ============
    
    function getCampaign(uint256 _campaignId)
        external
        view
        campaignExists(_campaignId)
        returns (
            address creator,
            string memory title,
            string memory description,
            uint256 goalKES,
            uint256 goalAVAX,
            uint256 deadline,
            uint256 totalDonationsAVAX,
            uint256 conversionRate,
            bool goalReached,
            bool finalized,
            uint256 milestonesCount,
            uint256 donorCount
        )
    {
        creator = campaigns[_campaignId].creator;
        title = campaigns[_campaignId].title;
        description = campaigns[_campaignId].description;
        goalKES = campaigns[_campaignId].goalKES;
        goalAVAX = campaigns[_campaignId].goalAVAX;
        deadline = campaigns[_campaignId].deadline;
        totalDonationsAVAX = campaigns[_campaignId].totalDonationsAVAX;
        conversionRate = campaigns[_campaignId].conversionRate;
        goalReached = campaigns[_campaignId].goalReached;
        finalized = campaigns[_campaignId].finalized;
        milestonesCount = campaigns[_campaignId].milestonesCount;
        donorCount = campaigns[_campaignId].donorList.length;
    }
    
    function getMilestone(uint256 _campaignId, uint256 _milestoneIndex)
        external
        view
        campaignExists(_campaignId)
        returns (
            string memory description,
            uint256 amountKES,
            uint256 amountAVAX,
            bool released,
            uint256 votesFor,
            uint256 votesAgainst,
            string memory evidenceURI,
            uint256 proposedAt
        )
    {
        require(_milestoneIndex < campaigns[_campaignId].milestonesCount, "Invalid milestone index");

        description = campaigns[_campaignId].milestones[_milestoneIndex].description;
        amountKES = campaigns[_campaignId].milestones[_milestoneIndex].amountKES;
        amountAVAX = campaigns[_campaignId].milestones[_milestoneIndex].amountAVAX;
        released = campaigns[_campaignId].milestones[_milestoneIndex].released;
        votesFor = campaigns[_campaignId].milestones[_milestoneIndex].votesFor;
        votesAgainst = campaigns[_campaignId].milestones[_milestoneIndex].votesAgainst;
        evidenceURI = campaigns[_campaignId].milestones[_milestoneIndex].evidenceURI;
        proposedAt = campaigns[_campaignId].milestones[_milestoneIndex].proposedAt;
    }
    
    function getDonation(uint256 _campaignId, address _donor)
        external
        view
        campaignExists(_campaignId)
        returns (uint256)
    {
        return campaigns[_campaignId].donations[_donor];
    }
    
    function getDonorList(uint256 _campaignId)
        external
        view
        campaignExists(_campaignId)
        returns (address[] memory)
    {
        return campaigns[_campaignId].donorList;
    }
}
