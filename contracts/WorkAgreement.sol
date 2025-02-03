// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

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
        // tokenAddressがaddress(0)の場合、ネイティブトークン（Ether）での入金とする
        address tokenAddress;
        JobStatus status;
        string title;
        string description;
        uint256 deadline;
        string jobURI;
        uint256 deliveredTimestamp;
        // deliverWork時に納品物のURLを記録するフィールド
        string submissionURI;
    }

    // --------------------------------------------------------------------------------
    // State Variables
    // --------------------------------------------------------------------------------

    uint256 public jobCounter;
    mapping(uint256 => Job) public jobs;

    address public disputeResolver;
    uint256 public constant AUTO_APPROVE_PERIOD = 7 days;

    // 管理者（owner）: 特定の操作の制御に利用
    address public owner;
    // 再入可能性対策用のロック変数
    bool private locked;

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
    // deliverWork時に納品物のURLを出力するように変更
    event JobDelivered(uint256 indexed jobId, string submissionURI);
    event JobCompleted(uint256 indexed jobId);
    event JobDisputed(uint256 indexed jobId);
    event JobResolved(uint256 indexed jobId, bool disputeUpheld);
    event JobCancelled(uint256 indexed jobId);
    event JobDeadlineCancelled(uint256 indexed jobId);

    // --------------------------------------------------------------------------------
    // Modifiers
    // --------------------------------------------------------------------------------

    modifier validJobId(uint256 _jobId) {
        require(_jobId != 0 && _jobId <= jobCounter, "Invalid job ID");
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

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    /// 再入攻撃対策の簡易的な修飾子（非再入可能）
    modifier nonReentrant() {
        require(!locked, "ReentrancyGuard: reentrant call");
        locked = true;
        _;
        locked = false;
    }

    // --------------------------------------------------------------------------------
    // Constructor
    // --------------------------------------------------------------------------------

    constructor(address _disputeResolver) {
        disputeResolver = _disputeResolver;
        owner = msg.sender;
    }

    // --------------------------------------------------------------------------------
    // Fallback / Receive
    // --------------------------------------------------------------------------------

    // ネイティブトークン受信用（直接Etherが送られた場合の対策）
    receive() external payable { }

    // --------------------------------------------------------------------------------
    // Internal Utility Functions
    // --------------------------------------------------------------------------------

    /**
     * @dev tokenAddress が address(0) の場合はネイティブトークンの送金を行い、
     *      それ以外の場合はERC20トークンのtransferを実行する。
     */
    function _transferFunds(
        address _tokenAddress,
        address _recipient,
        uint256 _amount
    )
        internal
        returns (bool)
    {
        if (_tokenAddress == address(0)) {
            // ネイティブ送金の場合、_recipient を payable にキャスト
            (bool success,) = payable(_recipient).call{ value: _amount }("");
            return success;
        } else {
            return IERC20(_tokenAddress).transfer(_recipient, _amount);
        }
    }

    // --------------------------------------------------------------------------------
    // Main Functions
    // --------------------------------------------------------------------------------

    /**
     * @notice クライアントが仕事を作成する（報酬のデポジット含む）
     * @dev _tokenAddress が address(0) の場合はネイティブトークン（Ether）での入金とする。
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
        payable
        returns (uint256 jobId)
    {
        require(_depositAmount > 0, "Deposit must be greater than 0");
        require(_deadline > block.timestamp, "Deadline must be in the future");

        if (_tokenAddress == address(0)) {
            // ネイティブトークンの場合、送信されたEther (msg.value) が _depositAmount と一致する必要がある
            require(msg.value == _depositAmount, "Sent value must equal deposit amount");
        } else {
            // ERC20の場合、msg.value は0である必要があり、approve済みのトークンから入金される
            require(msg.value == 0, "Do not send native token when using ERC20");
            bool success =
                IERC20(_tokenAddress).transferFrom(msg.sender, address(this), _depositAmount);
            require(success, "Token transfer failed");
        }

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
            deliveredTimestamp: 0,
            submissionURI: ""
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
     * @notice コントラクターが応募する
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
     * @notice クライアントが契約開始する（応募したコントラクターを選定）
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
     * @notice コントラクターが納品する（納品物のURLを指定）
     */
    function deliverWork(
        uint256 _jobId,
        string calldata _submissionURI
    )
        external
        validJobId(_jobId)
        onlyContractor(_jobId)
        validStatus(_jobId, JobStatus.InProgress)
    {
        Job storage job = jobs[_jobId];
        require(block.timestamp <= job.deadline, "Deadline passed, cannot deliver");

        job.status = JobStatus.Delivered;
        job.deliveredTimestamp = block.timestamp;
        job.submissionURI = _submissionURI;

        emit JobDelivered(_jobId, _submissionURI);
    }

    /**
     * @notice クライアントが納品を承認して job を完了する
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
     * @notice コントラクターが報酬を引き出す
     */
    function withdrawPayment(uint256 _jobId)
        external
        validJobId(_jobId)
        onlyContractor(_jobId)
        validStatus(_jobId, JobStatus.Completed)
        nonReentrant
    {
        Job storage job = jobs[_jobId];
        uint256 amount = job.depositAmount;
        job.depositAmount = 0;
        job.status = JobStatus.Resolved;

        bool success = _transferFunds(job.tokenAddress, msg.sender, amount);
        require(success, "Payment transfer failed");
    }

    /**
     * @notice 自動承認（納品後一定期間経過時にDeliveredからCompletedへ）
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
     * @notice 納品前に期限を過ぎた job を自動キャンセルする（InProgress状態かつdeadline超過）
     */
    function autoCancelIfDeadlinePassed(uint256 _jobId) external validJobId(_jobId) nonReentrant {
        Job storage job = jobs[_jobId];
        require(job.status == JobStatus.InProgress, "Invalid job status");
        require(block.timestamp > job.deadline, "Deadline not passed yet");

        job.status = JobStatus.Cancelled;
        uint256 amount = job.depositAmount;
        job.depositAmount = 0;

        bool success = _transferFunds(job.tokenAddress, job.client, amount);
        require(success, "Refund to client failed");

        emit JobDeadlineCancelled(_jobId);
    }

    /**
     * @notice 紛争を申し立てる（ClientまたはContractorが呼び出し可能）
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
     * @notice 紛争解決者が裁定する
     * @param _disputeUpheld trueの場合、Client勝訴（返金）、falseの場合、Contractor勝訴（支払い）
     */
    function resolveDispute(
        uint256 _jobId,
        bool _disputeUpheld
    )
        external
        validJobId(_jobId)
        onlyDisputeResolver
        validStatus(_jobId, JobStatus.Disputed)
        nonReentrant
    {
        Job storage job = jobs[_jobId];
        job.status = JobStatus.Resolved;
        uint256 amount = job.depositAmount;
        job.depositAmount = 0;

        bool success;
        if (_disputeUpheld) {
            // Client勝訴 → 返金
            success = _transferFunds(job.tokenAddress, job.client, amount);
            require(success, "Refund to client failed");
        } else {
            // Contractor勝訴 → 支払い
            success = _transferFunds(job.tokenAddress, job.contractor, amount);
            require(success, "Payment to contractor failed");
        }
        emit JobResolved(_jobId, _disputeUpheld);
    }

    /**
     * @notice Clientがjobをキャンセルする（Open状態のみ）
     */
    function cancelJob(uint256 _jobId)
        external
        validJobId(_jobId)
        onlyClient(_jobId)
        validStatus(_jobId, JobStatus.Open)
    {
        Job storage job = jobs[_jobId];
        job.status = JobStatus.Cancelled;
        uint256 amount = job.depositAmount;
        job.depositAmount = 0;

        bool success = _transferFunds(job.tokenAddress, msg.sender, amount);
        require(success, "Refund failed");
        emit JobCancelled(_jobId);
    }

    /**
     * @notice 指定されたjobの情報を返す
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
            uint256 deliveredAt_,
            string memory submissionURI_
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
            job.deliveredTimestamp,
            job.submissionURI
        );
    }

    /**
     * @notice 管理者(owner)のみが呼び出し可能: 紛争解決者の変更
     */
    function setDisputeResolver(address _resolver) external onlyOwner {
        disputeResolver = _resolver;
    }
}
