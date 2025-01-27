// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.23 <0.9.0;

import { Test } from "forge-std/src/Test.sol";
import "../../contracts/WorkAgreement.sol";
import { MockERC20 } from "../../contracts/test/MockERC20.sol";

contract WorkAgreement_Test is Test {
    WorkAgreement public workAgreement;
    MockERC20 public mockToken;

    // テスト用アドレス
    address public client;
    address public contractor;
    address public disputeResolver;

    // 定数
    uint256 public constant DEPOSIT_AMOUNT = 100 ether;
    string public constant JOB_URI = "ipfs://QmTest";

    // --------------------------------------------------------------------------------
    // setUp
    // --------------------------------------------------------------------------------

    function setUp() public {
        // テスト用アドレスを作成
        client = makeAddr("client");
        contractor = makeAddr("contractor");
        disputeResolver = makeAddr("disputeResolver");

        // MockERC20をデプロイ＆WorkAgreementをデプロイ
        mockToken = new MockERC20("Mock Token", "MTK");
        workAgreement = new WorkAgreement(disputeResolver);

        // クライアントにトークンをミントしてapprove
        mockToken.mint(client, DEPOSIT_AMOUNT);
        vm.prank(client);
        mockToken.approve(address(workAgreement), DEPOSIT_AMOUNT);
    }

    // --------------------------------------------------------------------------------
    // 正常系テスト (Success)
    // --------------------------------------------------------------------------------

    /// @dev it should successfully create a job.
    function test_SuccessWhen_CreateJob() external {
        // Act
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(address(mockToken), DEPOSIT_AMOUNT, JOB_URI);

        // Assert
        (
            address _client,
            address _contractor,
            uint256 _depositAmount,
            address _tokenAddress,
            WorkAgreement.JobStatus _status,
            string memory _jobURI,
            uint256 _deliveredTimestamp
        ) = workAgreement.getJob(jobId);

        assertEq(_client, client);
        assertEq(_contractor, address(0));
        assertEq(_depositAmount, DEPOSIT_AMOUNT);
        assertEq(_tokenAddress, address(mockToken));
        assertEq(uint256(_status), uint256(WorkAgreement.JobStatus.Open));
        assertEq(_jobURI, JOB_URI);
        assertEq(_deliveredTimestamp, 0, "deliveredTimestamp should be zero at creation");
    }

    /// @dev it should allow contractor to apply and client to start contract.
    function test_SuccessWhen_ApplyAndStartContract() external {
        // Arrange
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(address(mockToken), DEPOSIT_AMOUNT, JOB_URI);

        // Contractor applies
        vm.prank(contractor);
        workAgreement.applyForJob(jobId);

        // Client starts contract
        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // Assert
        (, address _contractor,,, WorkAgreement.JobStatus _status,,) = workAgreement.getJob(jobId);

        assertEq(_contractor, contractor, "Contractor should match");
        assertEq(uint256(_status), uint256(WorkAgreement.JobStatus.InProgress));
    }

    /// @dev it should allow the full lifecycle: create → apply → start → deliver → approve
    /// → withdraw.
    function test_SuccessWhen_FullLifecycle() external {
        // 1. Create
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(address(mockToken), DEPOSIT_AMOUNT, JOB_URI);

        // 2. Apply
        vm.prank(contractor);
        workAgreement.applyForJob(jobId);

        // 3. Start
        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // 4. Deliver
        vm.prank(contractor);
        workAgreement.deliverWork(jobId);

        // 5. Approve
        vm.prank(client);
        workAgreement.approveAndComplete(jobId);

        // 6. Withdraw
        uint256 contractorBalanceBefore = mockToken.balanceOf(contractor);
        vm.prank(contractor);
        workAgreement.withdrawPayment(jobId);
        uint256 contractorBalanceAfter = mockToken.balanceOf(contractor);

        assertEq(
            contractorBalanceAfter - contractorBalanceBefore,
            DEPOSIT_AMOUNT,
            "Contractor should receive deposit amount"
        );

        // 最終ステータス確認 (Resolved)
        (,,,, WorkAgreement.JobStatus _status,,) = workAgreement.getJob(jobId);
        assertEq(uint256(_status), uint256(WorkAgreement.JobStatus.Resolved));
    }

    /// @dev it should resolve dispute in contractor's favor (disputeUpheld = false).
    function test_SuccessWhen_Dispute_ContractorWins() external {
        // Create & Start
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(address(mockToken), DEPOSIT_AMOUNT, JOB_URI);

        vm.prank(contractor);
        workAgreement.applyForJob(jobId);

        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // Dispute
        vm.prank(client);
        workAgreement.raiseDispute(jobId);

        // Contractor Wins => disputeUpheld = false
        vm.prank(disputeResolver);
        workAgreement.resolveDispute(jobId, false);

        // Assert
        uint256 contractorBalance = mockToken.balanceOf(contractor);
        assertEq(contractorBalance, DEPOSIT_AMOUNT, "Contractor should receive deposit on success");

        (,, uint256 depositAmount,, WorkAgreement.JobStatus status,,) = workAgreement.getJob(jobId);
        assertEq(depositAmount, 0);
        assertEq(uint256(status), uint256(WorkAgreement.JobStatus.Resolved));
    }

    /// @dev it should resolve dispute in client's favor (disputeUpheld = true).
    function test_SuccessWhen_Dispute_ClientWins() external {
        // Create & Start
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(address(mockToken), DEPOSIT_AMOUNT, JOB_URI);

        vm.prank(contractor);
        workAgreement.applyForJob(jobId);

        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // Dispute
        vm.prank(client);
        workAgreement.raiseDispute(jobId);

        // Client Wins => disputeUpheld = true
        vm.prank(disputeResolver);
        workAgreement.resolveDispute(jobId, true);

        // Assert
        uint256 clientBalance = mockToken.balanceOf(client);
        // 当初 client は DEPOSIT_AMOUNTをコントラクトに送金→Dispute勝利で全額戻る
        assertEq(clientBalance, DEPOSIT_AMOUNT, "Client should get deposit refunded");

        (,, uint256 depositAmount,, WorkAgreement.JobStatus status,,) = workAgreement.getJob(jobId);
        assertEq(depositAmount, 0);
        assertEq(uint256(status), uint256(WorkAgreement.JobStatus.Resolved));
    }

    /// @dev it should auto-approve if the client does nothing within AUTO_APPROVE_PERIOD.
    function test_SuccessWhen_AutoApprovalAfterDeadline() external {
        // Create & Start
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(address(mockToken), DEPOSIT_AMOUNT, JOB_URI);

        vm.prank(contractor);
        workAgreement.applyForJob(jobId);

        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // Deliver
        vm.prank(contractor);
        workAgreement.deliverWork(jobId);

        // 時間経過 (7 days)
        skip(7 days);

        // Auto-approve
        workAgreement.autoApproveIfTimeoutPassed(jobId);

        // Assert => Completed
        (,,,, WorkAgreement.JobStatus status,,) = workAgreement.getJob(jobId);
        assertEq(uint256(status), uint256(WorkAgreement.JobStatus.Completed));
    }

    // --------------------------------------------------------------------------------
    // 異常系テスト (Reverts)
    // --------------------------------------------------------------------------------

    /// @dev it should revert if applying for a job that doesn't exist or invalid status.
    function test_RevertWhen_ApplyForNonExistentJob() external {
        vm.prank(contractor);
        vm.expectRevert("Invalid job status");
        workAgreement.applyForJob(9999); // jobId=9999は未作成想定
    }

    /// @dev it should revert if a second contractor tries to apply for the same job.
    function test_RevertWhen_ApplyTwice() external {
        // Create
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(address(mockToken), DEPOSIT_AMOUNT, JOB_URI);

        // 1st apply
        vm.prank(contractor);
        workAgreement.applyForJob(jobId);

        // 2nd apply => revert
        address anotherContractor = makeAddr("anotherContractor");
        vm.prank(anotherContractor);
        vm.expectRevert("Contractor already assigned");
        workAgreement.applyForJob(jobId);
    }

    /// @dev it should revert if contractor tries to withdraw before job completion.
    function test_RevertWhen_WithdrawWithoutCompletion() external {
        // Create & Start
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(address(mockToken), DEPOSIT_AMOUNT, JOB_URI);

        vm.prank(contractor);
        workAgreement.applyForJob(jobId);

        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // Withdraw => revert
        vm.prank(contractor);
        vm.expectRevert("Invalid job status");
        workAgreement.withdrawPayment(jobId);
    }

    /// @dev it should revert if autoApprove is called before the waiting period.
    function test_RevertWhen_AutoApproveBeforeDeadline() external {
        // Create & Deliver
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(address(mockToken), DEPOSIT_AMOUNT, JOB_URI);

        vm.prank(contractor);
        workAgreement.applyForJob(jobId);

        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        vm.prank(contractor);
        workAgreement.deliverWork(jobId);

        // まだ時間が経っていないので revert
        vm.expectRevert("Auto-approval period not passed");
        workAgreement.autoApproveIfTimeoutPassed(jobId);
    }

    /// @dev it should revert if autoApprove is called after a dispute has been raised.
    function test_RevertWhen_AutoApproveAfterDispute() external {
        // Create & Deliver
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(address(mockToken), DEPOSIT_AMOUNT, JOB_URI);

        vm.prank(contractor);
        workAgreement.applyForJob(jobId);

        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        vm.prank(contractor);
        workAgreement.deliverWork(jobId);

        // Raise dispute
        vm.prank(client);
        workAgreement.raiseDispute(jobId);

        // 時間経過してもDisputedなので autoApprove => revert
        skip(7 days);
        vm.expectRevert("Invalid job status");
        workAgreement.autoApproveIfTimeoutPassed(jobId);
    }
}
