// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title 業務委託契約 with Deadline Logic
 * @notice
 *  - 納品期限(deadline)を過ぎたら納品不可
 *  - 納品前にdeadlineを超過したら誰でもキャンセル可(報酬はクライアントに返還)
 *  - 納品が期限を超えて行われた場合にペナルティ計算の例をコメントで示す
 */
interface IERC20 {
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    )
        external
        returns (bool);

    function transfer(address recipient, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}

contract WorkAgreement {
    // --------------------------------------------------------------------------------
    // Enums
    // --------------------------------------------------------------------------------

    enum JobStatus {
        Open,
        InProgress,
        Delivered,
        Completed,
        Disputed,
        Resolved,
        Cancelled
    }

    // --------------------------------------------------------------------------------
    // Structs
    // --------------------------------------------------------------------------------

    struct Job {
        address client;
        address contractor;
        uint256 depositAmount;
        address tokenAddress;
        JobStatus status;
        string title;
        string description;
        uint256 deadline;
        string jobURI;
        uint256 deliveredTimestamp;
    }

    // --------------------------------------------------------------------------------
    // State Variables
    // --------------------------------------------------------------------------------

    uint256 public jobCounter;
    mapping(uint256 => Job) public jobs;

    address public disputeResolver;
    uint256 public constant AUTO_APPROVE_PERIOD = 7 days;

    // --------------------------------------------------------------------------------
    // Events
    // --------------------------------------------------------------------------------

    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        uint256 depositAmount,
        address token,
        string title,
        string description,
        uint256 deadline,
        string jobURI
    );
    event JobApplied(uint256 indexed jobId, address indexed contractor);
    event JobStarted(uint256 indexed jobId, address indexed contractor);
    event JobDelivered(uint256 indexed jobId);
    event JobCompleted(uint256 indexed jobId);
    event JobDisputed(uint256 indexed jobId);
    event JobResolved(uint256 indexed jobId, bool disputeUpheld);
    event JobCancelled(uint256 indexed jobId);
    event JobDeadlineCancelled(uint256 indexed jobId); // 期限超過によるキャンセル

    // --------------------------------------------------------------------------------
    // Modifiers
    // --------------------------------------------------------------------------------

    modifier validJobId(uint256 _jobId) {
        require(_jobId != 0 && _jobId <= jobCounter, "Invalid job status");
        _;
    }

    modifier validStatus(uint256 _jobId, JobStatus _requiredStatus) {
        require(jobs[_jobId].status == _requiredStatus, "Invalid job status");
        _;
    }

    modifier onlyClient(uint256 _jobId) {
        require(msg.sender == jobs[_jobId].client, "Only the client can call this function");
        _;
    }

    modifier onlyContractor(uint256 _jobId) {
        require(msg.sender == jobs[_jobId].contractor, "Only the contractor can call this function");
        _;
    }

    modifier onlyDisputeResolver() {
        require(msg.sender == disputeResolver, "Only the assigned dispute resolver can call");
        _;
    }

    // --------------------------------------------------------------------------------
    // Constructor
    // --------------------------------------------------------------------------------

    constructor(address _disputeResolver) {
        disputeResolver = _disputeResolver;
    }

    // --------------------------------------------------------------------------------
    // Main Functions
    // --------------------------------------------------------------------------------

    /**
     * @notice クライアントが仕事を作成する(報酬のデポジット含む)
     */
    function createJob(
        address _tokenAddress,
        uint256 _depositAmount,
        string calldata _title,
        string calldata _description,
        uint256 _deadline,
        string calldata _jobURI
    )
        external
        returns (uint256 jobId)
    {
        require(_depositAmount > 0, "Deposit must be greater than 0");
        require(_tokenAddress != address(0), "Invalid token address");
        // 例えば: require(_deadline > block.timestamp, "deadline must be in the future");

        IERC20 token = IERC20(_tokenAddress);
        bool success = token.transferFrom(msg.sender, address(this), _depositAmount);
        require(success, "Token transfer failed");

        jobCounter++;
        jobId = jobCounter;

        jobs[jobId] = Job({
            client: msg.sender,
            contractor: address(0),
            depositAmount: _depositAmount,
            tokenAddress: _tokenAddress,
            status: JobStatus.Open,
            title: _title,
            description: _description,
            deadline: _deadline,
            jobURI: _jobURI,
            deliveredTimestamp: 0
        });

        emit JobCreated(
            jobId,
            msg.sender,
            _depositAmount,
            _tokenAddress,
            _title,
            _description,
            _deadline,
            _jobURI
        );
    }

    /**
     * @notice コントラクターが応募
     */
    function applyForJob(uint256 _jobId)
        external
        validJobId(_jobId)
        validStatus(_jobId, JobStatus.Open)
    {
        require(jobs[_jobId].contractor == address(0), "Contractor already assigned");

        jobs[_jobId].contractor = msg.sender;
        emit JobApplied(_jobId, msg.sender);
    }

    /**
     * @notice クライアントが契約開始
     */
    function startContract(
        uint256 _jobId,
        address _selectedContractor
    )
        external
        validJobId(_jobId)
        onlyClient(_jobId)
        validStatus(_jobId, JobStatus.Open)
    {
        require(
            jobs[_jobId].contractor == _selectedContractor, "Not matched with selected contractor"
        );
        jobs[_jobId].status = JobStatus.InProgress;
        emit JobStarted(_jobId, _selectedContractor);
    }

    /**
     * @notice コントラクターが納品
     * @dev 期限を過ぎていればrevertする例
     */
    function deliverWork(uint256 _jobId)
        external
        validJobId(_jobId)
        onlyContractor(_jobId)
        validStatus(_jobId, JobStatus.InProgress)
    {
        Job storage job = jobs[_jobId];

        // 期限厳守の例
        require(block.timestamp <= job.deadline, "Deadline passed, cannot deliver");

        // （もしdeadline超過して納品したい場合、ペナルティ計算したうえで実行可能にするロジックに差し替えてもOK）
        // 例:
        // if (block.timestamp > job.deadline) {
        //     // 1日(86400秒)遅れるごとに10%減額する、など
        //     uint256 daysLate = (block.timestamp - job.deadline) / 1 days;
        //     uint256 penaltyRate = daysLate * 10; // % per day
        //     if (penaltyRate >= 100) {
        //         penaltyRate = 100;
        //     }
        //     uint256 penalty = (job.depositAmount * penaltyRate) / 100;
        //     job.depositAmount = job.depositAmount - penalty;
        // }

        job.status = JobStatus.Delivered;
        job.deliveredTimestamp = block.timestamp;

        emit JobDelivered(_jobId);
    }

    /**
     * @notice 納品後にクライアントが承認
     */
    function approveAndComplete(uint256 _jobId)
        external
        validJobId(_jobId)
        onlyClient(_jobId)
        validStatus(_jobId, JobStatus.Delivered)
    {
        jobs[_jobId].status = JobStatus.Completed;
        emit JobCompleted(_jobId);
    }

    /**
     * @notice コントラクターが報酬受け取り
     */
    function withdrawPayment(uint256 _jobId)
        external
        validJobId(_jobId)
        onlyContractor(_jobId)
        validStatus(_jobId, JobStatus.Completed)
    {
        Job storage job = jobs[_jobId];
        uint256 amount = job.depositAmount;
        job.depositAmount = 0;
        job.status = JobStatus.Resolved;

        IERC20 token = IERC20(job.tokenAddress);
        bool success = token.transfer(msg.sender, amount);
        require(success, "Payment transfer failed");
    }

    /**
     * @notice 自動承認 (Delivered→Completed)
     */
    function autoApproveIfTimeoutPassed(uint256 _jobId)
        external
        validJobId(_jobId)
        validStatus(_jobId, JobStatus.Delivered)
    {
        require(
            block.timestamp >= jobs[_jobId].deliveredTimestamp + AUTO_APPROVE_PERIOD,
            "Auto-approval period not passed"
        );

        jobs[_jobId].status = JobStatus.Completed;
        emit JobCompleted(_jobId);
    }

    /**
     * @notice 納品前に期限切れになったらキャンセル可能 (InProgress & deadline過ぎ)
     * @dev 誰でも呼べる例（本来はclientかcontractor、またはチェーン上の自動サービスなど？）
     */
    function autoCancelIfDeadlinePassed(uint256 _jobId) external validJobId(_jobId) {
        Job storage job = jobs[_jobId];

        // 「InProgress状態かつ未納品」を確認
        require(job.status == JobStatus.InProgress, "Invalid job status");
        require(block.timestamp > job.deadline, "Deadline not passed yet");

        // 自動キャンセル
        job.status = JobStatus.Cancelled;

        // depositをクライアントに返す
        IERC20 token = IERC20(job.tokenAddress);
        uint256 amount = job.depositAmount;
        job.depositAmount = 0;

        bool success = token.transfer(job.client, amount);
        require(success, "Refund to client failed");

        emit JobDeadlineCancelled(_jobId);
    }

    /**
     * @notice 納品物に異議がある場合は紛争へ (InProgress or Delivered)
     */
    function raiseDispute(uint256 _jobId) external validJobId(_jobId) {
        Job storage job = jobs[_jobId];
        require(msg.sender == job.client || msg.sender == job.contractor, "Not authorized");
        require(
            job.status == JobStatus.InProgress || job.status == JobStatus.Delivered,
            "Cannot dispute in this status"
        );
        job.status = JobStatus.Disputed;
        emit JobDisputed(_jobId);
    }

    /**
     * @notice 紛争解決者が裁定
     */
    function resolveDispute(
        uint256 _jobId,
        bool _disputeUpheld
    )
        external
        validJobId(_jobId)
        onlyDisputeResolver
        validStatus(_jobId, JobStatus.Disputed)
    {
        Job storage job = jobs[_jobId];
        job.status = JobStatus.Resolved;

        IERC20 token = IERC20(job.tokenAddress);
        uint256 amount = job.depositAmount;
        job.depositAmount = 0;

        if (_disputeUpheld) {
            // クライアント勝訴 -> 返金
            bool success = token.transfer(job.client, amount);
            require(success, "Refund to client failed");
        } else {
            // コントラクター勝訴 -> 支払い
            bool success = token.transfer(job.contractor, amount);
            require(success, "Payment to contractor failed");
        }

        emit JobResolved(_jobId, _disputeUpheld);
    }

    /**
     * @notice クライアントが仕事をキャンセル (Openのみ)
     */
    function cancelJob(uint256 _jobId)
        external
        validJobId(_jobId)
        onlyClient(_jobId)
        validStatus(_jobId, JobStatus.Open)
    {
        Job storage job = jobs[_jobId];
        job.status = JobStatus.Cancelled;

        IERC20 token = IERC20(job.tokenAddress);
        uint256 amount = job.depositAmount;
        job.depositAmount = 0;
        bool success = token.transfer(msg.sender, amount);
        require(success, "Refund failed");

        emit JobCancelled(_jobId);
    }

    // --------------------------------------------------------------------------------
    // View / Utility Functions
    // --------------------------------------------------------------------------------

    /**
     * @notice Jobの情報を返す
     */
    function getJob(uint256 _jobId)
        external
        view
        returns (
            address client_,
            address contractor_,
            uint256 depositAmount_,
            address tokenAddress_,
            JobStatus status_,
            string memory title_,
            string memory description_,
            uint256 deadline_,
            string memory jobURI_,
            uint256 deliveredAt_
        )
    {
        Job storage job = jobs[_jobId];
        return (
            job.client,
            job.contractor,
            job.depositAmount,
            job.tokenAddress,
            job.status,
            job.title,
            job.description,
            job.deadline,
            job.jobURI,
            job.deliveredTimestamp
        );
    }

    function setDisputeResolver(address _resolver) external {
        disputeResolver = _resolver;
    }
}
