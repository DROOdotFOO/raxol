// ACP buyer harness: hire our DEPLOYED solver (0x939...) via a real ACP order for the
// xochi_usdc_public offering, so its delegated send_calls (setBudget/submit/complete via
// the Privy+Alchemy sidecar) run on-chain. The BUYER is a Virtuals-managed agent
// (0x468a...) driven via the SDK's delegated PrivyAlchemyEvmProviderAdapter. The signed
// Xochi intent bundle is produced by the Elixir signer helper (any funded wallet -- the
// offering has NO same-owner gate) and read from BUNDLE_FILE. MOVES REAL FUNDS.
//
// Env: BUYER_WALLET_ADDRESS, BUYER_WALLET_ID, BUYER_SIGNER_KEY (P-256), SELLER,
//      BUNDLE_FILE, DST_CHAIN (default 42161), OFFERING (default xochi_usdc_public),
//      TIMEOUT_MS (default 300000), DRY (=1 -> stop after auth+lookup, no funds).
import { readFileSync } from "node:fs";
import { base } from "@account-kit/infra";
import { AcpAgent, PrivyAlchemyEvmProviderAdapter } from "@virtuals-protocol/acp-node-v2";

const need = (n) => {
  const v = process.env[n];
  if (!v) throw new Error(`missing env ${n}`);
  return v;
};

const SELLER = need("SELLER");
const OFFERING = process.env.OFFERING || "xochi_usdc_public";
const DST_CHAIN = Number(process.env.DST_CHAIN || "42161");
const ARB_USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
const bundle = JSON.parse(readFileSync(need("BUNDLE_FILE"), "utf8"));
const log = (m) => console.log(`[buyer] ${new Date().toISOString().slice(11, 19)} ${m}`);

async function main() {
  const adapter = await PrivyAlchemyEvmProviderAdapter.create({
    walletAddress: need("BUYER_WALLET_ADDRESS"),
    walletId: need("BUYER_WALLET_ID"),
    signerPrivateKey: need("BUYER_SIGNER_KEY"),
    chains: [base],
  });
  const buyer = await AcpAgent.create({ evmProvider: adapter });
  const meAddr = await buyer.getAddress();
  const me = meAddr.toLowerCase();
  log(`buyer ${meAddr}`);

  let done = false;
  const finish = async (why) => {
    if (done) return;
    done = true;
    log(`DONE: ${why}`);
    await buyer.stop().catch(() => {});
    process.exit(why.startsWith("completed") ? 0 : 1);
  };

  buyer.on("entry", async (session, entry) => {
    if (entry.kind === "system") {
      const ev = entry.event;
      log(`[job ${session.jobId}] event=${ev.type} ${JSON.stringify(ev).slice(0, 220)}`);
      try {
        switch (ev.type) {
          case "budget.set":
            log(`[job ${session.jobId}] seller proposed budget ${ev.amount} USDC -> funding fee`);
            await session.fetchJob();
            await session.fund();
            log(`[job ${session.jobId}] funded`);
            break;
          case "job.submitted":
            log(`[job ${session.jobId}] deliverable: ${JSON.stringify(ev.deliverable).slice(0, 400)}`);
            await session.complete("Evaluated: settlement delivered");
            log(`[job ${session.jobId}] completed by evaluator`);
            break;
          case "job.completed":
            return finish(`completed job ${session.jobId}`);
          case "job.rejected":
            return finish(`rejected job ${session.jobId}: ${ev.reason}`);
          case "job.expired":
            return finish(`expired job ${session.jobId}`);
        }
      } catch (e) {
        log(`[job ${session.jobId}] handler error on ${ev.type}: ${e?.message || e}`);
      }
    } else if (entry.kind === "message" && entry.from.toLowerCase() !== me) {
      log(`[job ${session.jobId}] msg from ${entry.from.slice(0, 8)}: ${entry.content}`);
    }
  });

  await buyer.start();
  log("started; looking up seller...");

  const agent = await buyer.getAgentByWalletAddress(SELLER);
  if (!agent) return finish(`no agent registered at ${SELLER}`);
  const offering = agent.offerings.find((o) => o.name === OFFERING);
  if (!offering) return finish(`offering ${OFFERING} not found (has: ${agent.offerings.map((o) => o.name).join(",")})`);
  log(`offering "${offering.name}" price=${offering.priceValue} requiredFunds=${offering.requiredFunds}`);

  if (process.env.DRY === "1") return finish(`completed dry-run: buyer auth OK, seller+offering found (no job, no funds)`);

  const requirement = {
    signed_intent: bundle,
    dst_chain_id: DST_CHAIN,
    dst_token: ARB_USDC,
    settlement_preference: "public",
  };
  log(`creating job (intent_id=${bundle.intent_id})...`);
  const jobId = await buyer.createJobFromOffering(base.id, offering, agent.walletAddress, requirement, { evaluatorAddress: meAddr });
  log(`job ${jobId} created -> waiting for deployed solver to fill via delegated send_calls`);

  setTimeout(() => finish("timeout waiting for completion"), Number(process.env.TIMEOUT_MS || "300000"));
}

main().catch((e) => {
  console.error("[buyer] fatal:", e?.stack || e);
  process.exit(1);
});
