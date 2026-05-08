#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

const ROOT = __dirname;
const DEFAULT_ABI_PATH = path.join(ROOT, "FlashExecutor.abi.json");

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function loadArtifact() {
  const artifactPath = process.env.CONTRACT_ARTIFACT_PATH;
  if (artifactPath) {
    const artifact = readJson(path.resolve(ROOT, artifactPath));
    const bytecode = artifact.bytecode?.object ?? artifact.bytecode;
    if (!artifact.abi || !bytecode) {
      throw new Error("Artifact must include abi and bytecode.");
    }
    return { abi: artifact.abi, bytecode };
  }

  const abi = readJson(DEFAULT_ABI_PATH);
  const bytecode = process.env.FLASH_EXECUTOR_BYTECODE;
  if (!bytecode) {
    throw new Error(
      "Set FLASH_EXECUTOR_BYTECODE or provide CONTRACT_ARTIFACT_PATH with abi+bytecode."
    );
  }
  return { abi, bytecode };
}

async function main() {
  const rpcUrl = process.env.RPC_URL;
  const privateKey = process.env.PRIVATE_KEY;
  if (!rpcUrl || !privateKey) {
    throw new Error("Set RPC_URL and PRIVATE_KEY.");
  }

  const { abi, bytecode } = loadArtifact();
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(privateKey, provider);
  const factory = new ethers.ContractFactory(abi, bytecode, wallet);

  console.log("Deploying FlashExecutor...");
  const contract = await factory.deploy();
  const deployTx = contract.deploymentTransaction();
  if (deployTx) {
    console.log(`Deployment tx: ${deployTx.hash}`);
  }

  await contract.waitForDeployment();
  const deployedAddress = await contract.getAddress();
  console.log(`FlashExecutor deployed at: ${deployedAddress}`);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
