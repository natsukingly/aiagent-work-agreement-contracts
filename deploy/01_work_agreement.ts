import type { DeployFunction, DeployResult } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";

import { preDeploy } from "../utils/contracts";
import { verifyContract } from "../utils/verify";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { getNamedAccounts, getChainId, deployments } = hre;
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();
  const chainId = await getChainId();

  // WorkAgreement のコンストラクタは disputeResolver のアドレスを受け取るため、
  // ここでは deployer を disputeResolver として利用します（必要に応じて変更してください）
  const disputeResolver = deployer;

  await preDeploy(deployer, "WorkAgreement");

  const deployResult: DeployResult = await deploy("WorkAgreement", {
    from: deployer,
    args: [disputeResolver],
    log: true,
    // 必要に応じて waitConfirmations を設定してください
    // waitConfirmations: 5,
  });

  // ローカルネットワーク以外の場合、Etherscan等での検証を行います
  if (chainId !== "31337" && chainId !== "1337") {
    const contractPath = `contracts/WorkAgreement.sol:WorkAgreement`;
    await verifyContract({
      contractPath,
      contractAddress: deployResult.address,
      args: deployResult.args || [],
    });
  }
};

export default func;
func.id = "deploy_workagreement";
func.tags = ["WorkAgreement"];
