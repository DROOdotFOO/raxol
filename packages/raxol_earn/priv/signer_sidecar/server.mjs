// raxol-earn signing sidecar.
//
// Wraps @virtuals-protocol/acp-node-v2's PrivyAlchemyEvmProviderAdapter and exposes
// the ProviderAdapter primitives over a localhost-only HTTP API, so the Elixir
// raxol_earn release can sign auth + settle ACP jobs AS a Virtuals-managed (Privy +
// Alchemy ERC-4337 / EIP-7702) agent wallet -- without holding any raw key. The
// P-256 authorization key lives ONLY in this process's env.
//
// Security posture: binds 127.0.0.1 only (no external port), and terminates when its
// parent (the BEAM) closes stdin -- so its lifetime is bound to the release.
//
// Endpoints (all JSON):
//   GET  /health          -> { ok, address, chainIds }
//   GET  /address         -> { address }
//   GET  /chains          -> { chainIds }
//   POST /sign-message    { chainId, message }            -> { signature }
//   POST /sign-typed-data { chainId, typedData }          -> { signature }
//   POST /send-calls      { chainId, calls:[{to,data,value?}] } -> { txHashes }
//   POST /receipt         { chainId, hash }               -> { receipt }
//   POST /read            { chainId, address, abi, functionName, args } -> { result }
//   POST /logs            { chainId, ...filter }          -> { logs }

import http from "node:http";
import { base } from "@account-kit/infra";
import { PrivyAlchemyEvmProviderAdapter } from "@virtuals-protocol/acp-node-v2";

const HOST = process.env.RAXOL_ACP_SIGNER_HOST || "127.0.0.1";
const PORT = Number(process.env.RAXOL_ACP_SIGNER_PORT || "4048");

function requireEnv(name) {
  const v = process.env[name];
  if (!v || v.trim() === "") {
    console.error(`[signer] missing required env ${name}`);
    process.exit(1);
  }
  return v;
}

// Only Base mainnet is wired -- the storefront authenticates and settles on Base.
// serverUrl / privyAppId default to the SDK's prod constants; override via env to
// point at a different ACP environment.
const CHAINS = [base];

// JSON.stringify cannot serialize BigInt; render as decimal string. Used for
// receipts/logs/read results that viem returns with bigint fields.
function jsonSafe(_key, value) {
  return typeof value === "bigint" ? value.toString() : value;
}

// Convert an incoming call's value (decimal string, 0x-hex, or number) to BigInt.
function toBigIntValue(v) {
  if (v === undefined || v === null) return undefined;
  if (typeof v === "bigint") return v;
  if (typeof v === "number") return BigInt(v);
  if (typeof v === "string") return v.startsWith("0x") ? BigInt(v) : BigInt(v);
  throw new Error(`unparseable call value: ${JSON.stringify(v)}`);
}

// viem TypedDataDefinition needs a primaryType. The Elixir side may omit it; infer
// it as the single non-EIP712Domain entry in `types`.
function withPrimaryType(typedData) {
  if (typedData.primaryType) return typedData;
  const keys = Object.keys(typedData.types || {}).filter(
    (k) => k !== "EIP712Domain",
  );
  if (keys.length !== 1) {
    throw new Error(
      `cannot infer primaryType from types keys: ${JSON.stringify(keys)}`,
    );
  }
  return { ...typedData, primaryType: keys[0] };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c) => {
      data += c;
      if (data.length > 5_000_000) reject(new Error("body too large"));
    });
    req.on("end", () => {
      if (data === "") return resolve({});
      try {
        resolve(JSON.parse(data));
      } catch (e) {
        reject(new Error(`invalid JSON body: ${e.message}`));
      }
    });
    req.on("error", reject);
  });
}

function send(res, status, obj) {
  const payload = JSON.stringify(obj, jsonSafe);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

// Map an adapter error onto a structured HTTP response. The SDK throws
// ApprovalRequiredError when a Privy wallet policy needs dashboard approval.
function errorResponse(res, err) {
  const name = err?.name || "";
  const msg = err?.shortMessage || err?.message || String(err);
  if (name === "ApprovalRequiredError" || err?.approvalId) {
    return send(res, 409, {
      error: "approval_required",
      approvalId: err.approvalId,
      approvalUrl: err.approvalUrl,
      detail: err.detail || msg,
    });
  }
  console.error(`[signer] error: ${msg}`);
  return send(res, 500, { error: "signer_error", detail: msg });
}

async function main() {
  const adapter = await PrivyAlchemyEvmProviderAdapter.create({
    walletAddress: requireEnv("RAXOL_ACP_WALLET_ADDRESS"),
    walletId: requireEnv("RAXOL_ACP_WALLET_ID"),
    signerPrivateKey: requireEnv("RAXOL_ACP_SIGNER_PRIVATE_KEY"),
    chains: CHAINS,
    ...(process.env.RAXOL_ACP_SERVER_URL
      ? { serverUrl: process.env.RAXOL_ACP_SERVER_URL }
      : {}),
    ...(process.env.PRIVY_APP_ID ? { privyAppId: process.env.PRIVY_APP_ID } : {}),
  });

  const address = await adapter.getAddress();
  const chainIds = await adapter.getSupportedChainIds();
  console.log(`[signer] ready: wallet ${address} chains ${chainIds.join(",")}`);

  const routes = {
    "GET /health": async () => ({ ok: true, address, chainIds }),
    "GET /address": async () => ({ address }),
    "GET /chains": async () => ({ chainIds }),
    "POST /sign-message": async (b) => ({
      signature: await adapter.signMessage(b.chainId, b.message),
    }),
    "POST /sign-typed-data": async (b) => ({
      signature: await adapter.signTypedData(
        b.chainId,
        withPrimaryType(b.typedData),
      ),
    }),
    "POST /send-calls": async (b) => {
      const calls = (b.calls || []).map((c) => {
        const value = toBigIntValue(c.value);
        return {
          to: c.to,
          data: c.data ?? "0x",
          ...(value !== undefined ? { value } : {}),
        };
      });
      const result = await adapter.sendTransaction(b.chainId, calls);
      const txHashes = Array.isArray(result) ? result : [result];
      return { txHashes };
    },
    "POST /receipt": async (b) => ({
      receipt: await adapter.getTransactionReceipt(b.chainId, b.hash),
    }),
    "POST /read": async (b) => ({
      result: await adapter.readContract(b.chainId, {
        address: b.address,
        abi: b.abi,
        functionName: b.functionName,
        args: b.args ?? [],
      }),
    }),
    "POST /logs": async (b) => {
      const { chainId, ...filter } = b;
      return { logs: await adapter.getLogs(chainId, filter) };
    },
  };

  const server = http.createServer(async (req, res) => {
    const key = `${req.method} ${req.url.split("?")[0]}`;
    const handler = routes[key];
    if (!handler) return send(res, 404, { error: "not_found", route: key });
    try {
      const body = req.method === "GET" ? {} : await readBody(req);
      const out = await handler(body);
      send(res, 200, out);
    } catch (err) {
      errorResponse(res, err);
    }
  });

  server.listen(PORT, HOST, () => {
    console.log(`[signer] listening on http://${HOST}:${PORT}`);
  });

  // Die with the parent: when the BEAM closes the port, stdin emits 'end'.
  process.stdin.resume();
  process.stdin.on("end", () => {
    console.log("[signer] parent closed stdin -- exiting");
    process.exit(0);
  });
  process.stdin.on("close", () => process.exit(0));
}

main().catch((e) => {
  console.error(`[signer] fatal: ${e?.stack || e}`);
  process.exit(1);
});
