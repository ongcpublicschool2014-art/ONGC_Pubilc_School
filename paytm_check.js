#!/usr/bin/env node
// Paytm credential checker.
// Tests a MID + Merchant Key against Paytm's Initiate Transaction API by
// creating a ₹1 order — this returns a token but MOVES NO MONEY, so it's a
// safe way to verify a MID/key pair before wiring it into the app.
//
// Usage:
//   node paytm_check.js <MID> <KEY> [website] [host]
//
// Defaults: website=DEFAULT, host=https://secure.paytmpayments.com (production)
// Staging:  node paytm_check.js <MID> <KEY> WEBSTAGING https://securestage.paytmpayments.com

const crypto = require("crypto");

const IV = "@@@@&&&&####$$$$";
const SALT_CHARS =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

function randomSalt(len = 4) {
  const b = crypto.randomBytes(len);
  let s = "";
  for (const x of b) s += SALT_CHARS[x % SALT_CHARS.length];
  return s;
}
function sha256Hex(s) {
  return crypto.createHash("sha256").update(s, "utf8").digest("hex");
}
function generateSignature(params, key) {
  const salt = randomSalt(4);
  const finalString = sha256Hex(params + "|" + salt) + salt;
  const cipher = crypto.createCipheriv(
    "aes-128-cbc",
    Buffer.from(key, "utf8"),
    Buffer.from(IV, "utf8"),
  );
  return cipher.update(finalString, "utf8", "base64") + cipher.final("base64");
}

async function main() {
  const [mid, key, website = "DEFAULT", host = "https://secure.paytmpayments.com", splitMid] =
    process.argv.slice(2);
  if (!mid || !key) {
    console.error("Usage: node paytm_check.js <MID> <KEY> [website] [host] [splitMID]");
    console.error("  Pass a 5th arg (a sub MID) to test SPLIT SETTLEMENT.");
    process.exit(1);
  }
  const orderId = "CHK-" + Date.now();
  const body = {
    requestType: "Payment",
    mid,
    websiteName: website,
    orderId,
    callbackUrl: "",
    txnAmount: { value: "1.00", currency: "INR" },
    userInfo: { custId: "CHECK" },
  };
  if (splitMid) {
    body.splitSettlementInfo = {
      splitType: "AT_TXN",
      splitMethod: "AMOUNT",
      splitInfo: [
        { mid: splitMid, amount: { value: "1.00", currency: "INR" }, splitReferenceId: orderId },
      ],
    };
    console.log(`Split settlement → ${splitMid}`);
  }
  const signature = generateSignature(JSON.stringify(body), key);
  const payload = { body, head: { signature } };
  const url = `${host}/theia/api/v1/initiateTransaction?mid=${mid}&orderId=${orderId}`;

  console.log(`MID: ${mid}  |  key length: ${key.length}${key.length !== 16 ? " (⚠ expected 16 — check for stray spaces)" : ""}  |  website: ${website}`);
  try {
    const resp = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const data = await resp.json();
    const ri = (data && data.body && data.body.resultInfo) || {};
    const token = data && data.body && data.body.txnToken;
    console.log(`resultCode: ${ri.resultCode}  |  ${ri.resultMsg}`);
    if (token) {
      if (splitMid) {
        console.log("✅ SPLIT SETTLEMENT ENABLED — order accepted with a split to the sub MID (no money moved).");
      } else {
        console.log("✅ WORKS — valid MID+key (order token issued, no money moved). Settles to THIS MID's registered bank.");
      }
    } else if (ri.resultCode === "2005") {
      console.log("❌ Checksum invalid — this KEY does not belong to this MID.");
    } else if (ri.resultCode === "501") {
      console.log(splitMid
        ? "❌ SPLIT SETTLEMENT NOT ENABLED (501). Ask Paytm to enable Split Settlement + onboard the sub MID."
        : "❌ System Error — MID not activated / not enabled on this host.");
    } else {
      console.log("❌ Not usable. Raw: " + JSON.stringify(data));
    }
  } catch (e) {
    console.log("Request failed: " + e.message);
  }
}
main();
