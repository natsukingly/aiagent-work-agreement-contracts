// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title 業務委託契約
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
        Open, // 募集中
        InProgress, // 作業中
        Delivered, // 納品完了(承認待ち)
        Completed, // 承認済み
        Disputed, // 紛争中
        Resolved, // 紛争解決済み（報酬配分も完了）
        Cancelled // キャンセル

    }

    // --------------------------------------------------------------------------------
    // Structs
    // --------------------------------------------------------------------------------

    struct Job {
        address client; // 発注(AI Agent)
        address contractor; // 受注(AI Agent)
        uint256 depositAmount; // デポジットされた報酬額
        address tokenAddress; // ERC20トークンのアドレス
        JobStatus status; // 仕事のステータス
        string jobURI; // 仕事詳細 (IPFS/ArweaveなどのURI)
        uint256 deliveredTimestamp; // 納品時刻 (自動承認のため)
    }

    // --------------------------------------------------------------------------------
    // State Variables
    // --------------------------------------------------------------------------------

    uint256 public jobCounter;
    mapping(uint256 => Job) public jobs;

    // 紛争解決者(第三者/DAOなど)のアドレス
    address public disputeResolver;

    // TODO:納品後どのくらい時間が経過したら自動承認になるか
    // 例: 7日 (86400秒 = 1日)
    uint256 public constant AUTO_APPROVE_PERIOD = 7 days;

    // --------------------------------------------------------------------------------
    // Events
    // --------------------------------------------------------------------------------

    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        uint256 depositAmount,
        address token,
        string jobURI
    );
    event JobApplied(uint256 indexed jobId, address indexed contractor);
    event JobStarted(uint256 indexed jobId, address indexed contractor);
    event JobDelivered(uint256 indexed jobId);
    event JobCompleted(uint256 indexed jobId);
    event JobDisputed(uint256 indexed jobId);
    event JobResolved(uint256 indexed jobId, bool disputeUpheld);
    event JobCancelled(uint256 indexed jobId);

    // --------------------------------------------------------------------------------
    // Modifiers
    // --------------------------------------------------------------------------------

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

    modifier validStatus(uint256 _jobId, JobStatus _requiredStatus) {
        require(jobs[_jobId].status == _requiredStatus, "Invalid job status");
        _;
    }

    // --------------------------------------------------------------------------------
    // Constructor
    // --------------------------------------------------------------------------------

    constructor(address _disputeResolver) {
        disputeResolver = _disputeResolver;
    }

    // --------------------------------------------------------------------------------
    // Public / External Functions
    // --------------------------------------------------------------------------------

    /**
     * @notice クライアントが仕事を作成する(報酬のデポジットを含む)
     */
    function createJob(
        address _tokenAddress,
        uint256 _depositAmount,
        string calldata _jobURI
    )
        external
        returns (uint256)
    {
        require(_depositAmount > 0, "Deposit must be greater than 0");
        require(_tokenAddress != address(0), "Invalid token address");

        IERC20 token = IERC20(_tokenAddress);
        bool success = token.transferFrom(msg.sender, address(this), _depositAmount);
        require(success, "Token transfer failed");

        jobCounter++;
        uint256 newJobId = jobCounter;

        jobs[newJobId] = Job({
            client: msg.sender,
            contractor: address(0),
            depositAmount: _depositAmount,
            tokenAddress: _tokenAddress,
            status: JobStatus.Open,
            jobURI: _jobURI,
            deliveredTimestamp: 0
        });

        emit JobCreated(newJobId, msg.sender, _depositAmount, _tokenAddress, _jobURI);
        return newJobId;
    }

    /**
     * @notice コントラクター(AI Agent)が仕事に応募
     */
    function applyForJob(uint256 _jobId) external validStatus(_jobId, JobStatus.Open) {
        // 簡易的に先着1名で確定
        require(jobs[_jobId].contractor == address(0), "Contractor already assigned");
        jobs[_jobId].contractor = msg.sender;

        emit JobApplied(_jobId, msg.sender);
    }

    /**
     * @notice クライアントが正式に採用(Contractを開始)
     */
    function startContract(
        uint256 _jobId,
        address _selectedContractor
    )
        external
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
     * @notice コントラクターが成果物納品
     */
    function deliverWork(uint256 _jobId)
        external
        onlyContractor(_jobId)
        validStatus(_jobId, JobStatus.InProgress)
    {
        Job storage job = jobs[_jobId];
        job.status = JobStatus.Delivered;
        // TODO:納品時刻を記録
        job.deliveredTimestamp = block.timestamp;

        emit JobDelivered(_jobId);
    }

    /**
     * @notice クライアントが納品物を承認し、仕事を完了
     */
    function approveAndComplete(uint256 _jobId)
        external
        onlyClient(_jobId)
        validStatus(_jobId, JobStatus.Delivered)
    {
        jobs[_jobId].status = JobStatus.Completed;
        emit JobCompleted(_jobId);
    }

    /**
     * @notice コントラクターが報酬を引き出す (Completed の状態のみ)
     */
    function withdrawPayment(uint256 _jobId)
        external
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
     * @notice 納品から一定時間経過後、誰でも呼び出して自動承認できる
     * @dev 期間内にクライアントがDisputeを起こさなければCompletedにする
     */
    function autoApproveIfTimeoutPassed(uint256 _jobId) external {
        Job storage job = jobs[_jobId];
        require(job.status == JobStatus.Delivered, "Job is not in Delivered status");

        require(
            block.timestamp >= job.deliveredTimestamp + AUTO_APPROVE_PERIOD,
            "Auto-approval period not passed"
        );

        // 紛争に移行されていなければ自動承認
        job.status = JobStatus.Completed;
        emit JobCompleted(_jobId);
    }

    /**
     * @notice 納品物に異議がある場合、クライアント or コントラクターがDisputeを開始
     */
    function raiseDispute(uint256 _jobId) external {
        Job storage job = jobs[_jobId];
        require(msg.sender == job.client || msg.sender == job.contractor, "Not authorized");
        // 納品後 or 作業中なら紛争を起こせる（CompletedやResolvedになる前に止める）
        require(
            job.status == JobStatus.InProgress || job.status == JobStatus.Delivered,
            "Cannot dispute in this status"
        );
        job.status = JobStatus.Disputed;

        emit JobDisputed(_jobId);
    }

    /**
     * @notice 紛争解決者が裁定(Disputeを解決)
     */
    function resolveDispute(
        uint256 _jobId,
        bool _disputeUpheld
    )
        external
        onlyDisputeResolver
        validStatus(_jobId, JobStatus.Disputed)
    {
        Job storage job = jobs[_jobId];
        job.status = JobStatus.Resolved;

        IERC20 token = IERC20(job.tokenAddress);
        uint256 amount = job.depositAmount;
        job.depositAmount = 0;

        if (_disputeUpheld) {
            // クライアント勝訴 -> デポジット返還
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
     * @notice クライアントが仕事をキャンセル
     */
    function cancelJob(uint256 _jobId)
        external
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
    // View / Utility functions
    // --------------------------------------------------------------------------------

    function getJob(uint256 _jobId)
        external
        view
        returns (
            address client,
            address contractor,
            uint256 depositAmount,
            address tokenAddress,
            JobStatus status,
            string memory jobURI,
            uint256 deliveredAt
        )
    {
        Job storage job = jobs[_jobId];
        return (
            job.client,
            job.contractor,
            job.depositAmount,
            job.tokenAddress,
            job.status,
            job.jobURI,
            job.deliveredTimestamp
        );
    }

    /**
     * @notice 紛争解決者のアドレスをセット (要アクセス制御検討)
     */
    function setDisputeResolver(address _resolver) external {
        // 本サンプルでは誰でも呼べる。実務ではOwnable等の導入推奨
        disputeResolver = _resolver;
    }
}
