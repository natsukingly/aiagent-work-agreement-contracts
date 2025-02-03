// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.23 <0.9.0;

import { Test } from "forge-std/src/Test.sol";
import "../../contracts/WorkAgreement.sol";
import { MockERC20 } from "../../contracts/test/MockERC20.sol";

/**
 * @title WorkAgreementWithDeadline_Test
 * @notice テストコード例
 */
contract WorkAgreementWithDeadline_Test is Test {
    WorkAgreement public workAgreement;
    MockERC20 public mockToken;

    // テスト用アドレス
    address public client;
    address public contractor;
    address public disputeResolver;

    // 定数
    uint256 public constant DEPOSIT_AMOUNT = 100 ether;
    // 締め切り (例: 今から3日後)
    uint256 public constant JOB_DEADLINE = 3 days;
    string public constant JOB_TITLE = "Test Job with Deadline";
    string public constant JOB_DESCRIPTION = "This job has a strict deadline.";
    string public constant JOB_URI = "ipfs://QmTest";
    // deliverWork 時に渡す納品物URL（サンプル）
    string public constant SUBMISSION_URI = "https://example.com/submission";

    // --------------------------------------------------------------------------------
    // setUp
    // --------------------------------------------------------------------------------
    function setUp() public {
        // テスト用アドレスの生成
        client = makeAddr("client");
        contractor = makeAddr("contractor");
        disputeResolver = makeAddr("disputeResolver");

        // 各アドレスに十分なEtherを付与（ネイティブトークン用）
        vm.deal(client, 1000 ether);
        vm.deal(contractor, 1000 ether);
        vm.deal(disputeResolver, 1000 ether);

        // コントラクトデプロイ
        mockToken = new MockERC20("Mock Token", "MTK");
        workAgreement = new WorkAgreement(disputeResolver);

        // ERC20テスト用: Clientにトークン付与＆approve
        mockToken.mint(client, DEPOSIT_AMOUNT);
        vm.prank(client);
        mockToken.approve(address(workAgreement), DEPOSIT_AMOUNT);
    }

    // --------------------------------------------------------------------------------
    // ERC20テストケース
    // --------------------------------------------------------------------------------

    /**
     * @dev 期限内に納品→承認→支払いまで完了するフロー（ERC20）
     */
    function test_SuccessWhen_FullLifecycle_BeforeDeadline() external {
        // 1. Client が job を作成
        vm.startPrank(client);
        uint256 jobId = workAgreement.createJob(
            address(mockToken),
            DEPOSIT_AMOUNT,
            JOB_TITLE,
            JOB_DESCRIPTION,
            block.timestamp + JOB_DEADLINE, // 現在時刻から3日後
            JOB_URI
        );
        vm.stopPrank();

        // 2. Contractor が応募
        vm.prank(contractor);
        workAgreement.applyForJob(jobId);

        // 3. Client が契約開始
        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // 4. Contractor が期限内に納品（納品物のURLを渡す）
        skip(2 days);
        vm.prank(contractor);
        workAgreement.deliverWork(jobId, SUBMISSION_URI);

        // 5. Client が納品を承認し、完了状態にする
        vm.prank(client);
        workAgreement.approveAndComplete(jobId);

        // 6. Contractor が報酬を引き出す
        uint256 contractorBalanceBefore = mockToken.balanceOf(contractor);
        vm.prank(contractor);
        workAgreement.withdrawPayment(jobId);
        uint256 contractorBalanceAfter = mockToken.balanceOf(contractor);

        // 検証: Contractor の残高が deposit 分増えていること
        assertEq(
            contractorBalanceAfter - contractorBalanceBefore,
            DEPOSIT_AMOUNT,
            "Contractor should get the full deposit"
        );
    }

    /**
     * @dev 期限を過ぎて納品しようとした場合 => revert（ERC20）
     */
    function test_RevertWhen_DeliverAfterDeadline() external {
        // 1. Client が job を作成
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(
            address(mockToken),
            DEPOSIT_AMOUNT,
            JOB_TITLE,
            JOB_DESCRIPTION,
            block.timestamp + JOB_DEADLINE,
            JOB_URI
        );

        // 2. Contractor が応募し、Client が契約開始
        vm.prank(contractor);
        workAgreement.applyForJob(jobId);
        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // 3. 期限を超えて納品を試みる（納品URLを指定）
        skip(4 days); // 期限(3日)を超過
        vm.startPrank(contractor);
        vm.expectRevert("Deadline passed, cannot deliver");
        workAgreement.deliverWork(jobId, SUBMISSION_URI);
        vm.stopPrank();
    }

    /**
     * @dev 期限超過になった job を自動キャンセル（ERC20）
     */
    function test_SuccessWhen_AutoCancelIfDeadlinePassed() external {
        // 1. Client が job を作成
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(
            address(mockToken),
            DEPOSIT_AMOUNT,
            JOB_TITLE,
            JOB_DESCRIPTION,
            block.timestamp + JOB_DEADLINE,
            JOB_URI
        );

        // 2. Contractor が応募し、Client が契約開始
        vm.prank(contractor);
        workAgreement.applyForJob(jobId);
        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // 3. 納品がなく、期限を超過
        skip(4 days);

        // 4. autoCancelIfDeadlinePassed を呼び出してキャンセル処理
        vm.expectEmit(true, true, false, false);
        emit WorkAgreement.JobDeadlineCancelled(jobId);
        workAgreement.autoCancelIfDeadlinePassed(jobId);

        // 5. Job 情報を取得し、deposit が返金済み（0になっている）およびステータスが Cancelled であることを検証
        (,, uint256 depositAmount,, WorkAgreement.JobStatus status,,,,,,) =
            workAgreement.getJob(jobId);
        assertEq(depositAmount, 0, "Deposit should be 0 after refund");
        assertEq(uint256(status), uint256(WorkAgreement.JobStatus.Cancelled));
    }

    /**
     * @dev 紛争のテスト（納期前に納品し、Client が Dispute、最終的に Contractor 勝訴）（ERC20）
     */
    function test_SuccessWhen_Dispute_ContractorWins() external {
        // 1. Client が job を作成
        vm.prank(client);
        uint256 jobId = workAgreement.createJob(
            address(mockToken),
            DEPOSIT_AMOUNT,
            JOB_TITLE,
            JOB_DESCRIPTION,
            block.timestamp + JOB_DEADLINE,
            JOB_URI
        );

        // 2. Contractor が応募し、Client が契約開始
        vm.prank(contractor);
        workAgreement.applyForJob(jobId);
        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // 3. Contractor が納品（納品物URLを指定）
        skip(1 days);
        vm.prank(contractor);
        workAgreement.deliverWork(jobId, SUBMISSION_URI);

        // 4. Client が Dispute（異議申し立て）
        vm.prank(client);
        workAgreement.raiseDispute(jobId);

        // 5. DisputeResolver が裁定し、Contractor 勝訴（false を渡す）
        vm.prank(disputeResolver);
        workAgreement.resolveDispute(jobId, false);

        // 6. Contractor に全額支払いされることを検証
        uint256 contractorBalance = mockToken.balanceOf(contractor);
        assertEq(contractorBalance, DEPOSIT_AMOUNT);
    }

    // --------------------------------------------------------------------------------
    // ネイティブトークン（Ether）を使ったテストケース
    // --------------------------------------------------------------------------------

    /**
     * @dev 期限内に納品→承認→支払いまで完了するフロー（ネイティブトークン）
     */
    function test_SuccessWhen_FullLifecycle_BeforeDeadline_Native() external {
        // 1. Client がネイティブトークンで job を作成
        vm.startPrank(client);
        uint256 jobId = workAgreement.createJob{ value: DEPOSIT_AMOUNT }(
            address(0), // ネイティブトークンの場合は address(0)
            DEPOSIT_AMOUNT,
            JOB_TITLE,
            JOB_DESCRIPTION,
            block.timestamp + JOB_DEADLINE,
            JOB_URI
        );
        vm.stopPrank();

        // 2. Contractor が応募
        vm.prank(contractor);
        workAgreement.applyForJob(jobId);

        // 3. Client が契約開始
        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // 4. Contractor が期限内に納品（納品物URLを渡す）
        skip(2 days);
        vm.prank(contractor);
        workAgreement.deliverWork(jobId, SUBMISSION_URI);

        // 5. Client が納品を承認し、完了状態にする
        vm.prank(client);
        workAgreement.approveAndComplete(jobId);

        // 6. Contractor が報酬（ネイティブトークン）を引き出す
        vm.prank(contractor);
        workAgreement.withdrawPayment(jobId);
        // withdrawPayment後、コントラクト残高が0であることを検証
        assertEq(
            address(workAgreement).balance,
            0,
            "Contract native balance should be zero after withdrawal"
        );
    }

    /**
     * @dev 期限を過ぎて納品しようとした場合 => revert（ネイティブトークン）
     */
    function test_RevertWhen_DeliverAfterDeadline_Native() external {
        // 1. Client がネイティブトークンで job を作成
        vm.prank(client);
        uint256 jobId = workAgreement.createJob{ value: DEPOSIT_AMOUNT }(
            address(0),
            DEPOSIT_AMOUNT,
            JOB_TITLE,
            JOB_DESCRIPTION,
            block.timestamp + JOB_DEADLINE,
            JOB_URI
        );

        // 2. Contractor が応募し、Client が契約開始
        vm.prank(contractor);
        workAgreement.applyForJob(jobId);
        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // 3. 期限を超えて納品を試みる（納品URLを指定）
        skip(4 days);
        vm.startPrank(contractor);
        vm.expectRevert("Deadline passed, cannot deliver");
        workAgreement.deliverWork(jobId, SUBMISSION_URI);
        vm.stopPrank();
    }

    /**
     * @dev 期限超過になった job を自動キャンセル（ネイティブトークン）
     */
    function test_SuccessWhen_AutoCancelIfDeadlinePassed_Native() external {
        // 1. Client がネイティブトークンで job を作成
        vm.prank(client);
        uint256 jobId = workAgreement.createJob{ value: DEPOSIT_AMOUNT }(
            address(0),
            DEPOSIT_AMOUNT,
            JOB_TITLE,
            JOB_DESCRIPTION,
            block.timestamp + JOB_DEADLINE,
            JOB_URI
        );

        // 2. Contractor が応募し、Client が契約開始
        vm.prank(contractor);
        workAgreement.applyForJob(jobId);
        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // 3. 納品がなく、期限を超過
        skip(4 days);

        // 4. autoCancelIfDeadlinePassed を呼び出してキャンセル処理
        vm.expectEmit(true, true, false, false);
        emit WorkAgreement.JobDeadlineCancelled(jobId);
        workAgreement.autoCancelIfDeadlinePassed(jobId);

        // 5. Job 情報を取得し、deposit が返金済み（0になっている）およびステータスが Cancelled であることを検証
        (,, uint256 depositAmount,, WorkAgreement.JobStatus status,,,,,,) =
            workAgreement.getJob(jobId);
        assertEq(depositAmount, 0, "Deposit should be 0 after refund");
        assertEq(uint256(status), uint256(WorkAgreement.JobStatus.Cancelled));
        assertEq(
            address(workAgreement).balance,
            0,
            "Contract native balance should be zero after auto-cancel"
        );
    }

    /**
     * @dev 紛争のテスト（納期前に納品し、Client が Dispute、最終的に Contractor 勝訴）（ネイティブトークン）
     */
    function test_SuccessWhen_Dispute_ContractorWins_Native() external {
        // 1. Client がネイティブトークンで job を作成
        vm.prank(client);
        uint256 jobId = workAgreement.createJob{ value: DEPOSIT_AMOUNT }(
            address(0),
            DEPOSIT_AMOUNT,
            JOB_TITLE,
            JOB_DESCRIPTION,
            block.timestamp + JOB_DEADLINE,
            JOB_URI
        );

        // 2. Contractor が応募し、Client が契約開始
        vm.prank(contractor);
        workAgreement.applyForJob(jobId);
        vm.prank(client);
        workAgreement.startContract(jobId, contractor);

        // 3. Contractor が納品（納品物URLを指定）
        skip(1 days);
        vm.prank(contractor);
        workAgreement.deliverWork(jobId, SUBMISSION_URI);

        // 4. Client が Dispute（異議申し立て）
        vm.prank(client);
        workAgreement.raiseDispute(jobId);

        // 5. DisputeResolver が裁定し、Contractor 勝訴（false を渡す）
        vm.prank(disputeResolver);
        workAgreement.resolveDispute(jobId, false);

        // 6. ネイティブトークンでの支払いが完了していることを検証（contract残高が0であればOK）
        assertEq(
            address(workAgreement).balance,
            0,
            "Contract native balance should be zero after dispute resolution"
        );
    }
}
