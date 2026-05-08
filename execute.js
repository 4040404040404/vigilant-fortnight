#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

const ROOT = __dirname;
const ABI_CANDIDATES = [
  path.join(ROOT, "FlashExecutor.abi.json"),
  path.join(ROOT, "flashexecutor.abi.json"),
];

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function loadAbi() {
  for (const abiPath of ABI_CANDIDATES) {
    if (fs.existsSync(abiPath)) return readJson(abiPath);
  }
  throw new Error("ABI file not found. Expected FlashExecutor.abi.json.");
}

function asBigInt(value, field) {
  try {
    return BigInt(value);
  } catch {
    throw new Error(`Invalid numeric value for ${field}: ${value}`);
  }
}

function assertAddress(value, field, allowZero = false) {
  const isZero = value === "0x0000000000000000000000000000000000000000";
  if (!ethers.isAddress(value) || (!allowZero && isZero)) {
    throw new Error(`Invalid address for ${field}: ${value}`);
  }
}

function loadConfig() {
  const configPath = process.env.EXECUTE_CONFIG_PATH;
  if (!configPath) {
    throw new Error("Set EXECUTE_CONFIG_PATH to a JSON config file.");
  }

  const config = readJson(path.resolve(ROOT, configPath));
  assertAddress(config.flashCurrency, "flashCurrency", true);
  assertAddress(config.recipient, "recipient");

  if (!Array.isArray(config.steps) || config.steps.length === 0) {
    throw new Error("steps must be a non-empty array.");
  }

  const normalizedSteps = config.steps.map((step, idx) => {
    if (!step?.key) throw new Error(`steps[${idx}].key is required.`);
    assertAddress(step.key.currency0, `steps[${idx}].key.currency0`, true);
    assertAddress(step.key.currency1, `steps[${idx}].key.currency1`, true);
    assertAddress(step.key.hooks, `steps[${idx}].key.hooks`, true);

    return {
      key: {
        currency0: step.key.currency0,
        currency1: step.key.currency1,
        fee: Number(step.key.fee),
        tickSpacing: Number(step.key.tickSpacing),
        hooks: step.key.hooks,
      },
      zeroForOne: Boolean(step.zeroForOne),
      amountIn: asBigInt(step.amountIn, `steps[${idx}].amountIn`),
      minAmountOut: asBigInt(step.minAmountOut, `steps[${idx}].minAmountOut`),
    };
  });

  return {
    flashCurrency: config.flashCurrency,
    flashAmount: asBigInt(config.flashAmount, "flashAmount"),
    steps: normalizedSteps,
    minProfit: asBigInt(config.minProfit, "minProfit"),
    recipient: config.recipient,
  };
}

async function main() {
  const rpcUrl = process.env.RPC_URL;
  const privateKey = process.env.PRIVATE_KEY;
  const executorAddress = process.env.EXECUTOR_ADDRESS;
  if (!rpcUrl || !privateKey || !executorAddress) {
    throw new Error("Set RPC_URL, PRIVATE_KEY, and EXECUTOR_ADDRESS.");
  }
  assertAddress(executorAddress, "EXECUTOR_ADDRESS");

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(privateKey, provider);
  const abi = loadAbi();
  const executor = new ethers.Contract(executorAddress, abi, wallet);
  const params = loadConfig();

  const txOverrides = {};
  if (process.env.GAS_LIMIT) txOverrides.gasLimit = asBigInt(process.env.GAS_LIMIT, "GAS_LIMIT");
  if (process.env.VALUE) txOverrides.value = asBigInt(process.env.VALUE, "VALUE");

  console.log("Sending execute() transaction...");
  const tx = await executor.execute(
    params.flashCurrency,
    params.flashAmount,
    params.steps,
    params.minProfit,
    params.recipient,
    txOverrides
  );
  console.log(`Tx hash: ${tx.hash}`);

  const confirmations = Number(process.env.WAIT_CONFIRMATIONS || "1");
  const receipt = await tx.wait(confirmations);
  console.log(`Mined in block: ${receipt.blockNumber}`);
  console.log(`Status: ${receipt.status === 1 ? "success" : "failed"}`);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
